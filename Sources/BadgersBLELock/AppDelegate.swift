import Cocoa
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = ProximityMonitor()
    private let prefs = UserDefaults.standard
    private var pairingWizard: PairingWizard?
    private let header = MenuHeaderView()

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
        refreshStatusItem()
    }

    /// The screen unlock event is a distributed notification, no entitlement or
    /// permission needed.
    private func observeUnlock() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleUnlock()
        }
    }

    private func handleUnlock() {
        guard enabled, monitor.monitoredUUID != nil else { return }
        // Present already? Then this was an ordinary unlock and nothing changes.
        guard !monitor.present else { return }
        NSLog("Unlocked with the phone away — pausing until it returns")
        suspended = true
    }

    private func applyThresholds() {
        monitor.lockRSSI = lockRSSI
        // 8 dB of hysteresis: you must come back meaningfully closer than the
        // point at which you triggered a lock, otherwise it flaps at the boundary.
        monitor.presentRSSI = lockRSSI + 8
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

    private func deviceName(for uuid: UUID) -> String {
        monitor.discovered[uuid]?.name ?? uuid.uuidString
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
            NSLog("Could not change Start at Login: \(error.localizedDescription)")
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

    @objc private func lockNow() {
        Locker.lock()
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
            NSLog("Phone back in range — resuming")
            suspended = false
        }
        refreshStatusItem()
        guard !present, enabled, !suspended, monitor.monitoredUUID != nil else { return }
        guard !Locker.isScreenLocked else { return }
        NSLog("Locking screen (\(reason))")
        Locker.lock()
    }

    func monitorDidUpdatePending(_ pending: Bool) {
        refreshStatusItem()
    }

    func monitorDidUpdateDeviceList() {}
}
