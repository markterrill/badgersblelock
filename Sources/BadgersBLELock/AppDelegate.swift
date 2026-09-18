import Cocoa
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = ProximityMonitor()
    private let prefs = UserDefaults.standard
    private var pairingWizard: PairingWizard?
    private let header = MenuHeaderView()
    private var activityWindow: ActivityLogWindow?

    /// Set when you unlock the Mac while the phone is out of range. Unlocking by
    /// hand is you saying "I am here, my phone is not" — so locking pauses until
    /// the phone actually comes back, rather than locking you out again.
    ///
    /// Deliberately not persisted: this is a fact about the current session, and
    /// writing it to prefs would mean one phoneless unlock silently disarmed the
    /// app for good.
    private var suspended = false {
        didSet { if suspended != oldValue { refreshStatusItem() } }
    }

    private var lockRSSI: Int {
        get { prefs.object(forKey: "lockRSSI") as? Int ?? -58 }
        set {
            prefs.set(newValue, forKey: "lockRSSI")
            applyThresholds()
        }
    }

    /// Seconds of weak signal before locking. Offered as a menu of round numbers
    /// rather than a free-form field: the useful range is "almost immediately" to
    /// "I stepped out for a coffee", and nothing in between needs finer control.
    private static let lockDelays = [4, 10, 20, 30, 40, 50, 60, 120, 300]

    /// How far above the lock threshold the signal must climb to call off a
    /// pending lock, in dB. Offered as an offset rather than an absolute number
    /// because it only means anything relative to the lock threshold: 0 removes
    /// the hysteresis entirely and lets the signal flap across a single line.
    private static let returnOffsets = [0, 2, 4, 5, 6, 8, 10]

    private var returnOffset: Int {
        get { prefs.object(forKey: "returnOffset") as? Int ?? 5 }
        set {
            prefs.set(newValue, forKey: "returnOffset")
            applyThresholds()
        }
    }

    private func returnTitle(_ offset: Int) -> String {
        switch offset {
        case 0:  return "\(lockRSSI) dBm — same as lock (no hysteresis)"
        default: return "\(lockRSSI + offset) dBm — \(offset) dB above lock"
        }
    }

    /// The picker only offers devices this strong. Your phone is on the desk in
    /// front of you when you pair it, so anything further away is a neighbour's
    /// laptop, not the thing you are looking for.
    private static let pickerRSSI = -55

    private var lockDelay: Int {
        get { prefs.object(forKey: "lockDelay") as? Int ?? 10 }
        set {
            prefs.set(newValue, forKey: "lockDelay")
            applyThresholds()
        }
    }

    private static func delayTitle(_ seconds: Int) -> String {
        switch seconds {
        case ..<60: return "\(seconds) seconds"
        case 60:    return "1 minute"
        default:    return "\(seconds / 60) minutes"
        }
    }

    private var enabled: Bool {
        get { prefs.object(forKey: "enabled") as? Bool ?? true }
        set { prefs.set(newValue, forKey: "enabled"); refreshStatusItem() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = buildMenu()
        statusItem.menu?.delegate = self

        monitor.delegate = self
        applyThresholds()
        observeUnlock()
        if let saved = prefs.string(forKey: "monitoredUUID"), let uuid = UUID(uuidString: saved) {
            monitor.monitoredUUID = uuid
        } else {
            // Give CoreBluetooth a moment to power up and hear a few devices
            // before the wizard shows an empty list.
            Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                self?.startPairing()
            }
        }

        // After the saved device is restored, so the header does not report
        // "paired_device=none" on every launch.
        ActivityLog.shared.startSession(diagnosticHeader())
        ActivityLog.shared.record(.ok, "launched", "Badgers BLE Lock started",
            action: Locker.canLockDirectly
                ? "Ready, using the system lock"
                : "Ready, but the system lock is unavailable — will sleep the display instead",
            fields: ["can_lock_directly": "\(Locker.canLockDirectly)"])
        refreshStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ActivityLog.shared.record(.ok, "quit", "Badgers BLE Lock quit",
                                  action: "Monitoring stopped")
        ActivityLog.shared.flushPendingTail()
    }

    /// The screen unlock event is a distributed notification, no entitlement or
    /// permission needed.
    private func observeUnlock() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.monitor.systemSleeping = false
            self?.handleUnlock()
        }
        // The radio goes down as the machine sleeps, before the screen reports
        // itself locked — so the lock state alone would call that a failure.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification,
                              object: nil, queue: .main) { [weak self] _ in
            self?.monitor.systemSleeping = true
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                              object: nil, queue: .main) { [weak self] _ in
            self?.monitor.systemSleeping = false
        }
    }

    private func handleUnlock() {
        guard enabled, monitor.monitoredUUID != nil else { return }
        // Present already? Then this was an ordinary unlock and nothing changes.
        guard !monitor.present else { return }
        ActivityLog.shared.record(.warn, "suspended",
            "You unlocked the Mac while the phone was out of range",
            action: "Locking paused until the phone is back above \(monitor.presentRSSI) dBm",
            fields: ["clears_at_rssi": "\(monitor.presentRSSI)",
                     "last_rssi": monitor.smoothedRSSI.map { "\($0)" } ?? "none"])
        suspended = true
    }

    /// The settings and machine facts that decide everything else, gathered in
    /// one place so the log file and a copied report say the same thing.
    private func diagnosticHeader() -> [String: String] {
        var h: [String: String] = [
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "macos": ProcessInfo.processInfo.operatingSystemVersionString,
            "enabled": "\(enabled)",
            "suspended": "\(suspended)",
            "lock_rssi_threshold": "\(lockRSSI)",
            "return_rssi_threshold": "\(lockRSSI + returnOffset)",
            "return_offset_db": "\(returnOffset)",
            "smoothing_seconds": "\(Int(monitor.smoothingSeconds))",
            "lock_delay_seconds": "\(lockDelay)",
            "away_samples_required": "\(monitor.awaySamples)",
            "away_seconds_required": "\(Int(monitor.awaySeconds))",
            "warmup_seconds": "\(Int(monitor.warmupSeconds))",
            "poll_interval_seconds": "\(monitor.pollInterval)",
            "blip_grace_seconds": "\(Int(monitor.blipGrace))",
            "signal_timeout_seconds": "\(Int(monitor.signalTimeout))",
            "can_lock_directly": "\(Locker.canLockDirectly)",
            "screen_locked_now": "\(Locker.isScreenLocked)",
            "paired_device": monitor.monitoredUUID.map { deviceName(for: $0) } ?? "none",
            "current_rssi": monitor.smoothedRSSI.map { "\($0)" } ?? "no signal",
        ]
        if #available(macOS 13.0, *) {
            h["start_at_login"] = "\(SMAppService.mainApp.status == .enabled)"
        }
        return h
    }

    private func applyThresholds() {
        monitor.lockRSSI = lockRSSI
        // You must come back meaningfully closer than the point at which the
        // countdown started, otherwise it flaps at the boundary.
        monitor.presentRSSI = lockRSSI + returnOffset
        monitor.awayDelay = Double(lockDelay)
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let headerItem = NSMenuItem()
        headerItem.view = header
        menu.addItem(headerItem)
        menu.addItem(.separator())

        // Looked up by identifier below rather than by index: the header pushed
        // everything down once already.
        let signalItem = NSMenuItem(title: "Signal: —", action: nil, keyEquivalent: "")
        signalItem.identifier = NSUserInterfaceItemIdentifier("signal")
        menu.addItem(signalItem)
        let deviceLine = NSMenuItem(title: "Device: none", action: nil, keyEquivalent: "")
        deviceLine.identifier = NSUserInterfaceItemIdentifier("device")
        menu.addItem(deviceLine)
        menu.addItem(.separator())

        let pairItem = NSMenuItem(title: "Pair Device…", action: #selector(startPairing), keyEquivalent: "")
        pairItem.target = self
        menu.addItem(pairItem)

        let deviceItem = NSMenuItem(title: "Select Device", action: nil, keyEquivalent: "")
        deviceItem.submenu = NSMenu()
        menu.addItem(deviceItem)

        let thresholdItem = NSMenuItem(title: "Lock Threshold", action: nil, keyEquivalent: "")
        let thresholdMenu = NSMenu()
        for value in stride(from: -45, through: -90, by: -3) {
            let item = NSMenuItem(title: "\(value) dBm", action: #selector(selectThreshold(_:)), keyEquivalent: "")
            item.target = self
            item.tag = value
            thresholdMenu.addItem(item)
        }
        thresholdItem.submenu = thresholdMenu
        menu.addItem(thresholdItem)

        let returnItem = NSMenuItem(title: "Return Threshold", action: nil, keyEquivalent: "")
        let returnMenu = NSMenu()
        for offset in Self.returnOffsets {
            let item = NSMenuItem(title: returnTitle(offset),
                                  action: #selector(selectReturnOffset(_:)), keyEquivalent: "")
            item.target = self
            item.tag = offset
            returnMenu.addItem(item)
        }
        returnItem.submenu = returnMenu
        menu.addItem(returnItem)

        let delayItem = NSMenuItem(title: "Lock Delay", action: nil, keyEquivalent: "")
        let delayMenu = NSMenu()
        for seconds in Self.lockDelays {
            let item = NSMenuItem(title: Self.delayTitle(seconds),
                                  action: #selector(selectDelay(_:)), keyEquivalent: "")
            item.target = self
            item.tag = seconds
            delayMenu.addItem(item)
        }
        delayItem.submenu = delayMenu
        menu.addItem(delayItem)

        let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.identifier = NSUserInterfaceItemIdentifier("enabled")
        menu.addItem(enabledItem)

        // SMAppService arrived in macOS 13. The deployment target is 12, so on
        // an older system the item is simply absent rather than dead.
        if #available(macOS 13.0, *) {
            let loginItem = NSMenuItem(title: "Start at Login",
                                       action: #selector(toggleStartAtLogin), keyEquivalent: "")
            loginItem.target = self
            loginItem.identifier = NSUserInterfaceItemIdentifier("login")
            menu.addItem(loginItem)
        }

        menu.addItem(.separator())
        let activity = NSMenuItem(title: "Activity Log…", action: #selector(showActivity),
                                  keyEquivalent: "")
        activity.target = self
        menu.addItem(activity)

        let lockNow = NSMenuItem(title: "Lock Now", action: #selector(lockNow), keyEquivalent: "l")
        lockNow.target = self
        menu.addItem(lockNow)
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    /// Red the moment the countdown starts, not when it finishes: the whole point
    /// of a long delay is being able to see the lock coming.
    private var currentState: PawIcon.State {
        if !enabled { return .disabled }
        if suspended { return .suspended }
        return (monitor.present && !monitor.pendingAway) ? .present : .pending
    }

    private func refreshStatusItem() {
        guard let button = statusItem.button else { return }
        let state = currentState
        button.image = PawIcon.image(for: state)
        // Keep the header live too, in case the menu is open while this fires.
        header.update(state)
    }

    /// Names are remembered across launches. At startup the phone has not been
    /// heard from yet, so the live table is empty and the menu and the
    /// diagnostics header would otherwise show a raw UUID for the first minute.
    private func deviceName(for uuid: UUID) -> String {
        var cache = prefs.dictionary(forKey: "deviceNames") as? [String: String] ?? [:]
        if let live = monitor.discovered[uuid]?.name, live != uuid.uuidString {
            if cache[uuid.uuidString] != live {
                cache[uuid.uuidString] = live
                prefs.set(cache, forKey: "deviceNames")
            }
            return live
        }
        return cache[uuid.uuidString] ?? uuid.uuidString
    }

    // MARK: - Actions

    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? UUID else { return }
        prefs.set(uuid.uuidString, forKey: "monitoredUUID")
        monitor.monitoredUUID = uuid
        suspended = false
        refreshStatusItem()
    }

    @objc private func startPairing() {
        let wizard = PairingWizard(monitor: monitor) { [weak self] uuid in
            guard let self else { return }
            self.prefs.set(uuid.uuidString, forKey: "monitoredUUID")
            self.monitor.monitoredUUID = uuid
            self.suspended = false
            self.refreshStatusItem()
        }
        pairingWizard = wizard
        wizard.present()
    }

    @objc private func selectThreshold(_ sender: NSMenuItem) {
        lockRSSI = sender.tag
    }

    @objc private func selectReturnOffset(_ sender: NSMenuItem) {
        returnOffset = sender.tag
    }

    @objc private func selectDelay(_ sender: NSMenuItem) {
        lockDelay = sender.tag
    }

    @objc private func toggleEnabled() {
        // Toggling by hand is an explicit re-arm.
        suspended = false
        enabled.toggle()
    }

    /// Registers the app itself as a login item — no helper bundle, no privileged
    /// install. Deliberately keeps no preference of its own: the system holds the
    /// truth, and the user can switch it off in System Settings without the two
    /// disagreeing.
    @objc private func toggleStartAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            ActivityLog.shared.record(.fail, "login_item_failed",
                "Could not change Start at Login: \(error.localizedDescription)",
                action: "Setting unchanged")
            let alert = NSAlert()
            alert.messageText = "Could not change Start at Login"
            // Overwhelmingly the cause is the app sitting somewhere transient:
            // registration records a path, and a rebuild invalidates it.
            alert.informativeText = """
                \(error.localizedDescription)

                Move BadgersBLELock to your Applications folder and try again — \
                launching it from a build directory registers a path that stops \
                working as soon as it is rebuilt.
                """
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func showActivity() {
        if activityWindow == nil {
            activityWindow = ActivityLogWindow(header: { [weak self] in
                self?.diagnosticHeader() ?? [:]
            })
        }
        activityWindow?.present()
    }

    @objc private func lockNow() {
        ActivityLog.shared.record(.ok, "lock_manual", "Lock Now chosen from the menu",
                                  action: "Locking the screen")
        attemptLock(reason: "manual")
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu == statusItem.menu else { return }
        monitor.pruneDiscovered()

        header.update(currentState)

        func item(_ id: String) -> NSMenuItem? {
            menu.items.first { $0.identifier?.rawValue == id }
        }
        let rssiText = monitor.smoothedRSSI.map { "\($0) dBm" } ?? "no signal"
        item("signal")?.title = suspended
            ? "Signal: \(rssiText) — paused until phone returns"
            : "Signal: \(rssiText)"
        item("device")?.title = monitor.monitoredUUID
            .map { "Device: \(deviceName(for: $0))" } ?? "Device: none"

        if let submenu = menu.item(withTitle: "Select Device")?.submenu {
            submenu.removeAllItems()
            // The monitored device stays listed however weak it is, otherwise it
            // drops off the menu the moment you walk away and you cannot see
            // what is actually selected.
            let sorted = monitor.discovered.values
                .filter { $0.rssi >= Self.pickerRSSI || $0.uuid == monitor.monitoredUUID }
                .sorted { $0.rssi > $1.rssi }
            if sorted.isEmpty {
                let title = monitor.discovered.isEmpty
                    ? "Scanning…"
                    : "Nothing within \(Self.pickerRSSI) dBm"
                submenu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
            }
            for device in sorted {
                let item = NSMenuItem(title: "\(device.name)  (\(device.rssi) dBm)",
                                      action: #selector(selectDevice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device.uuid
                item.state = device.uuid == monitor.monitoredUUID ? .on : .off
                submenu.addItem(item)
            }
        }

        if let submenu = menu.item(withTitle: "Lock Threshold")?.submenu {
            for item in submenu.items { item.state = item.tag == lockRSSI ? .on : .off }
        }
        // Titles are rebuilt on every open: they show absolute dBm, which moves
        // whenever the lock threshold changes.
        if let submenu = menu.item(withTitle: "Return Threshold")?.submenu {
            for item in submenu.items {
                item.title = returnTitle(item.tag)
                item.state = item.tag == returnOffset ? .on : .off
            }
        }

        if let submenu = menu.item(withTitle: "Lock Delay")?.submenu {
            for item in submenu.items { item.state = item.tag == lockDelay ? .on : .off }
        }
        item("enabled")?.state = enabled ? .on : .off

        if #available(macOS 13.0, *), let loginItem = item("login") {
            let status = SMAppService.mainApp.status
            loginItem.state = status == .enabled ? .on : .off
            // If login items were denied for this app, saying so beats a checkbox
            // that silently refuses to stay ticked.
            loginItem.title = status == .requiresApproval
                ? "Start at Login (approve in System Settings)"
                : "Start at Login"
        }
    }
}

extension AppDelegate: ProximityMonitorDelegate {
    func monitorDidUpdateRSSI(_ rssi: Int?, active: Bool) {}

    func monitorDidUpdatePresence(_ present: Bool, reason: String) {
        if present && suspended {
            suspended = false
            ActivityLog.shared.record(.ok, "resumed",
                "Phone returned while locking was paused",
                action: "Locking re-armed")
        }
        refreshStatusItem()
        guard !present else { return }

        // Each condition reported separately. As one compound guard this
        // returned silently, so "it just didn't lock" produced no evidence at
        // all about which of four reasons was responsible.
        if !enabled {
            ActivityLog.shared.record(.warn, "lock_skipped",
                "Phone is away, but monitoring is switched off",
                action: "No lock", fields: ["reason": "disabled"])
            return
        }
        if suspended {
            ActivityLog.shared.record(.warn, "lock_skipped",
                "Phone is away, but locking is paused because you unlocked while it was away",
                action: "No lock until the phone returns",
                fields: ["reason": "suspended",
                         "clears_at_rssi": "\(monitor.presentRSSI)"])
            return
        }
        if monitor.monitoredUUID == nil {
            ActivityLog.shared.record(.warn, "lock_skipped", "No phone has been paired",
                action: "No lock", fields: ["reason": "no_device"])
            return
        }
        if Locker.isScreenLocked {
            ActivityLog.shared.record(.ok, "lock_skipped", "Screen is already locked",
                action: "Nothing to do", fields: ["reason": "already_locked"])
            return
        }

        attemptLock(reason: reason)
    }

    /// Locking is attempted, verified, and reported — the previous code logged
    /// "Locking screen" *before* the call and discarded its result, so a lock
    /// that silently failed looked identical to one that worked.
    private func attemptLock(reason: String) {
        let direct = Locker.lock()
        ActivityLog.shared.record(direct ? .ok : .warn, "lock_attempted",
            "Phone away (\(reason)) — locking the screen",
            action: direct ? "Called the system lock" : "System lock unavailable, slept the display instead",
            fields: ["reason": reason, "method": direct ? "SACLockScreenImmediate" : "display_sleep"])

        // Verify rather than assume. The display-sleep fallback only locks if
        // "Require password immediately after sleep" is set, and that is a
        // per-machine setting this app cannot see directly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if Locker.isScreenLocked {
                ActivityLog.shared.record(.ok, "lock_confirmed", "Screen is locked",
                                          action: "Done")
            } else {
                ActivityLog.shared.record(.fail, "lock_failed",
                    "Screen did NOT lock two seconds after the attempt",
                    action: "Machine is still unlocked",
                    fields: ["method": direct ? "SACLockScreenImmediate" : "display_sleep",
                             "fix": "System Settings > Lock Screen > Require password immediately after sleep"])
            }
        }
    }

    func monitorDidUpdatePending(_ pending: Bool) {
        refreshStatusItem()
    }

    func monitorDidUpdateDeviceList() {
        // Side effect: caches the name for the next launch.
        if let uuid = monitor.monitoredUUID { _ = deviceName(for: uuid) }
    }
}
