import Foundation
import CoreBluetooth

/// Resolve a paired device's Bluetooth name via the system's CoreBluetooth cache.
/// Only works for devices already paired with this Mac, which is exactly our case.
private func pairedName(forUUID uuid: String) -> String? {
    guard let plist = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.Bluetooth.plist"),
          let cache = plist["CoreBluetoothCache"] as? NSDictionary,
          let entry = cache[uuid] as? NSDictionary,
          let mac = entry["DeviceAddress"] as? String,
          let devices = plist["DeviceCache"] as? NSDictionary,
          let device = devices[mac] as? NSDictionary,
          let name = device["Name"] as? String
    else { return nil }
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? nil : trimmed
}

struct DiscoveredDevice {
    let uuid: UUID
    var name: String
    var rssi: Int
    var lastSeen: Date
}

protocol ProximityMonitorDelegate: AnyObject {
    /// Smoothed RSSI for the monitored device, or nil when the signal is lost.
    func monitorDidUpdateRSSI(_ rssi: Int?, active: Bool)
    /// Called once on each present -> away and away -> present transition.
    func monitorDidUpdatePresence(_ present: Bool, reason: String)
    /// Called when the lock countdown starts or is called off, so the UI can show
    /// that a lock is coming before it actually happens.
    func monitorDidUpdatePending(_ pending: Bool)
    func monitorDidUpdateDeviceList()
}

final class ProximityMonitor: NSObject {
    // Tunables
    var lockRSSI = -58          // sustained signal weaker than this => away
    var presentRSSI = -50       // signal stronger than this => back
    /// Seconds below lockRSSI before declaring away. Changing it cancels any
    /// countdown already running, so a new value takes effect immediately rather
    /// than after the old one expires.
    var awayDelay = 10.0 { didSet { if awayDelay != oldValue { cancelAwayTimer() } } }
    var signalTimeout = 60.0    // seconds with no packet at all before declaring away
    var smoothingWindow = 5
    /// Coming back has to be sustained, not just glimpsed: this many samples in a
    /// row above presentRSSI, spanning at least returnDwell seconds. A single
    /// stray strong packet used to be enough, and since RSSI swings ~15 dB at the
    /// edge of range, that re-armed the state machine over and over and locked
    /// the screen once per spike.
    var returnSamples = 3
    var returnDwell = 3.0

    weak var delegate: ProximityMonitorDelegate?
    private(set) var discovered: [UUID: DiscoveredDevice] = [:]
    private(set) var present = false
    private(set) var smoothedRSSI: Int?
    /// True while the away countdown is running: the signal is below the lock
    /// threshold, but it has not been weak for long enough to act on yet.
    var pendingAway: Bool { awayTimer != nil }

    var monitoredUUID: UUID? {
        didSet { restart() }
    }

    private var central: CBCentralManager!
    private var monitoredPeripheral: CBPeripheral?
    private var samples: [Int] = []
    private var awayTimer: Timer?
    private var signalTimer: Timer?
    private var activeTimer: Timer?
    private var lastReadAt = Date.distantPast
    private var hasSeenDevice = false
    private var returnStreak = 0
    private var returnStreakStart: Date?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    private func restart() {
        if let p = monitoredPeripheral { central.cancelPeripheralConnection(p) }
        monitoredPeripheral = nil
        activeTimer?.invalidate(); activeTimer = nil
        awayTimer?.invalidate(); awayTimer = nil
        signalTimer?.invalidate(); signalTimer = nil
        samples.removeAll()
        smoothedRSSI = nil
        hasSeenDevice = false
        resetReturnStreak()
        present = true          // assume present until proven otherwise; never lock on launch
        delegate?.monitorDidUpdatePending(false)
        startScan()
    }

    private func startScan() {
        guard central.state == .poweredOn, !central.isScanning else { return }
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    /// Suppresses pruning while the pairing wizard is reasoning about which
    /// devices came and went, since it needs the full history of the session.
    var pairingActive = false

    /// Devices that have advertised since `date` — the pairing wizard's primitive
    /// for "was this device switched on during that window?"
    func devicesSeen(since date: Date) -> [DiscoveredDevice] {
        discovered.values.filter { $0.lastSeen >= date }
    }

    /// Drop devices we haven't heard from in a while so the picker stays honest.
    func pruneDiscovered() {
        guard !pairingActive else { return }
        let cutoff = Date().addingTimeInterval(-30)
        let before = discovered.count
        discovered = discovered.filter { $0.value.lastSeen > cutoff || $0.key == monitoredUUID }
        if discovered.count != before { delegate?.monitorDidUpdateDeviceList() }
    }

    // MARK: - Presence state machine

    private func ingest(rssi: Int) {
        hasSeenDevice = true
        resetSignalTimer()

        // Coming back is judged on raw samples so it reacts quickly, but it has
        // to hold up for a moment first — see returnSamples.
        if !present {
            if rssi >= presentRSSI {
                let start = returnStreakStart ?? Date()
                returnStreakStart = start
                returnStreak += 1
                if returnStreak >= returnSamples,
                   Date().timeIntervalSince(start) >= returnDwell {
                    present = true
                    resetReturnStreak()
                    samples.removeAll()   // don't let old weak samples drag us straight back out
                    delegate?.monitorDidUpdatePresence(true, reason: "close")
                }
            } else {
                resetReturnStreak()
            }
        }

        samples.append(rssi)
        if samples.count > smoothingWindow { samples.removeFirst() }
        let mean = Int(samples.reduce(0, +) / samples.count)
        smoothedRSSI = mean
        delegate?.monitorDidUpdateRSSI(mean, active: activeTimer != nil)

        // Leaving is judged on the smoothed value plus a dwell timer.
        if mean >= lockRSSI {
            cancelAwayTimer()
        } else if present && awayTimer == nil {
            awayTimer = Timer.scheduledTimer(withTimeInterval: awayDelay, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.present = false
                self.awayTimer = nil
                self.delegate?.monitorDidUpdatePresence(false, reason: "away")
            }
            RunLoop.main.add(awayTimer!, forMode: .common)
            delegate?.monitorDidUpdatePending(true)
        }
    }

    private func resetReturnStreak() {
        returnStreak = 0
        returnStreakStart = nil
    }

    private func cancelAwayTimer() {
        guard awayTimer != nil else { return }
        awayTimer?.invalidate()
        awayTimer = nil
        delegate?.monitorDidUpdatePending(false)
    }

    private func resetSignalTimer() {
        signalTimer?.invalidate()
        // Silence is a stronger signal of absence than a weak reading, but it
        // still must not lock sooner than the delay you asked for.
        let timeout = max(signalTimeout, awayDelay)
        signalTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.smoothedRSSI = nil
            self.delegate?.monitorDidUpdateRSSI(nil, active: false)
            if self.present {
                self.present = false
                self.delegate?.monitorDidUpdatePresence(false, reason: "lost")
            }
        }
        RunLoop.main.add(signalTimer!, forMode: .common)
    }

    /// Connecting to the phone lets us poll RSSI directly, which is far steadier
    /// than waiting on whatever advertising packets happen to land.
    private func enterActiveMode(_ peripheral: CBPeripheral) {
        guard activeTimer == nil else { return }
        activeTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastReadAt) > 10 {
                self.central.cancelPeripheralConnection(peripheral)
                self.activeTimer?.invalidate(); self.activeTimer = nil
                self.startScan()
            } else if peripheral.state == .connected {
                peripheral.readRSSI()
            } else if peripheral.state == .disconnected {
                self.central.connect(peripheral, options: nil)
            }
        }
        RunLoop.main.add(activeTimer!, forMode: .common)
    }
}

extension ProximityMonitor: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { startScan() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let rssi = RSSI.intValue > 0 ? 0 : RSSI.intValue
        let uuid = peripheral.identifier

        let name = pairedName(forUUID: uuid.description)
            ?? peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? uuid.uuidString
        if var existing = discovered[uuid] {
            existing.rssi = rssi
            existing.name = name
            existing.lastSeen = Date()
            discovered[uuid] = existing
        } else if rssi > -75 || uuid == monitoredUUID {
            // Only surface nearby devices in the picker; distant noise is unhelpful.
            discovered[uuid] = DiscoveredDevice(uuid: uuid, name: name, rssi: rssi, lastSeen: Date())
            delegate?.monitorDidUpdateDeviceList()
        }

        guard uuid == monitoredUUID else { return }
        if monitoredPeripheral == nil {
            monitoredPeripheral = peripheral
            peripheral.delegate = self
        }
        if activeTimer == nil {
            ingest(rssi: rssi)
            if peripheral.state == .disconnected { central.connect(peripheral, options: nil) }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == monitoredUUID else { return }
        peripheral.delegate = self
        peripheral.readRSSI()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        guard peripheral.identifier == monitoredUUID else { return }
        startScan()
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard peripheral.identifier == monitoredUUID else { return }
        lastReadAt = Date()
        ingest(rssi: RSSI.intValue > 0 ? 0 : RSSI.intValue)
        enterActiveMode(peripheral)
    }
}
