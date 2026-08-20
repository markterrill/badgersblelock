import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = ProximityMonitor()
    private let prefs = UserDefaults.standard
    private var pairingWizard: PairingWizard?

    private var lockRSSI: Int {
        get { prefs.object(forKey: "lockRSSI") as? Int ?? -58 }
        set {
            prefs.set(newValue, forKey: "lockRSSI")
            applyThresholds()
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

    private func applyThresholds() {
        monitor.lockRSSI = lockRSSI
        // 8 dB of hysteresis: you must come back meaningfully closer than the
        // point at which you triggered a lock, otherwise it flaps at the boundary.
        monitor.presentRSSI = lockRSSI + 8
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Signal: —", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Device: none", action: nil, keyEquivalent: ""))
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

        let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.identifier = NSUserInterfaceItemIdentifier("enabled")
        menu.addItem(enabledItem)

        menu.addItem(.separator())
        let lockNow = NSMenuItem(title: "Lock Now", action: #selector(lockNow), keyEquivalent: "l")
        lockNow.target = self
        menu.addItem(lockNow)
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    private func refreshStatusItem() {
        guard let button = statusItem.button else { return }
        let name = enabled ? (monitor.present ? "lock.open" : "lock") : "lock.slash"
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "BadgersBLELock")
        button.image?.isTemplate = true
    }

    private func deviceName(for uuid: UUID) -> String {
        monitor.discovered[uuid]?.name ?? uuid.uuidString
    }

    // MARK: - Actions

    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? UUID else { return }
        prefs.set(uuid.uuidString, forKey: "monitoredUUID")
        monitor.monitoredUUID = uuid
        refreshStatusItem()
    }

    @objc private func startPairing() {
        let wizard = PairingWizard(monitor: monitor) { [weak self] uuid in
            guard let self else { return }
            self.prefs.set(uuid.uuidString, forKey: "monitoredUUID")
            self.monitor.monitoredUUID = uuid
            self.refreshStatusItem()
        }
        pairingWizard = wizard
        wizard.present()
    }

    @objc private func selectThreshold(_ sender: NSMenuItem) {
        lockRSSI = sender.tag
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
    }

    @objc private func lockNow() {
        Locker.lock()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu == statusItem.menu else { return }
        monitor.pruneDiscovered()

        let rssiText = monitor.smoothedRSSI.map { "\($0) dBm" } ?? "no signal"
        menu.item(at: 0)?.title = "Signal: \(rssiText)"
        menu.item(at: 1)?.title = monitor.monitoredUUID
            .map { "Device: \(deviceName(for: $0))" } ?? "Device: none"

        if let submenu = menu.item(withTitle: "Select Device")?.submenu {
            submenu.removeAllItems()
            let sorted = monitor.discovered.values.sorted { $0.rssi > $1.rssi }
            if sorted.isEmpty {
                submenu.addItem(NSMenuItem(title: "Scanning…", action: nil, keyEquivalent: ""))
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
        menu.items.first { $0.identifier?.rawValue == "enabled" }?.state = enabled ? .on : .off
    }
}

extension AppDelegate: ProximityMonitorDelegate {
    func monitorDidUpdateRSSI(_ rssi: Int?, active: Bool) {}

    func monitorDidUpdatePresence(_ present: Bool, reason: String) {
        refreshStatusItem()
        guard !present, enabled, monitor.monitoredUUID != nil else { return }
        guard !Locker.isScreenLocked else { return }
        NSLog("Locking screen (\(reason))")
        Locker.lock()
    }

    func monitorDidUpdateDeviceList() {}
}
