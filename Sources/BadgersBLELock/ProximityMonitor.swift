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
    /// Seconds below lockRSSI before declaring away. Changing it abandons any
    /// countdown already running, so a new value takes effect immediately rather
    /// than after the old one expires.
    var awayDelay = 10.0 { didSet { if awayDelay != oldValue { abandonCountdown("delay changed") } } }
    /// Weak readings in a row before the countdown starts at all. One dip is
    /// noise, not a departure. This is a floor on the EVIDENCE, not on the time:
    /// packets can arrive several times a second while scanning, so three of
    /// them can span a fraction of a second.
    var awaySamples = 3
    /// ...which is why weakness must also persist for this long. Counting
    /// samples alone once locked the screen one second after launch, off three
    /// readings taken before the connection had even settled.
    var awaySeconds = 3.0
    /// Nothing may lock until monitoring has been running this long, OR until
    /// the connection is up, whichever comes first. The first readings after
    /// launch are taken while still scanning and read far weaker than the
    /// truth; connecting ends that condition outright, measured at about a
    /// second. The full wait is only the backstop for when no connection is
    /// established at all — which, if the phone really is gone, it will not be.
    var warmupSeconds = 10.0
    /// A recovered signal PAUSES the countdown rather than resetting it, and
    /// only abandons it after this long back above the threshold. Resetting on
    /// every blip meant a long delay could never elapse: RSSI swings ~15 dB, so
    /// the countdown restarted from zero over and over while you walked away.
    var blipGrace = 5.0
    /// How often the countdown advances. Also the resolution of its logging.
    private let tick = 1.0
    var signalTimeout = 60.0    // seconds with no packet at all before declaring away
    /// Smoothing is over a window of TIME, not a count of samples. A 5-sample
    /// window barely smoothed at all while scanning, where packets can arrive
    /// several times a second — which is how a phone sitting on the desk could
    /// read -48 one moment and -61 a few seconds later, and start a countdown.
    ///
    /// The length is set by the slower of the two modes. Steady state is the
    /// connected one, polling RSSI every `pollInterval`, so this window is
    /// sized to hold about four polls: fewer and one bad reading moves the mean
    /// too far, more and the lock is needlessly late. Measured on a paired
    /// iPhone: 0.5 packets/sec at a 2 s poll, hence the poll is 1 s.
    var smoothingSeconds = 4.0
    /// How often RSSI is read over an open connection. The connection is
    /// already up, so this is close to free; it is not worth going below the
    /// phone's own connection interval, where reads just repeat the last packet.
    var pollInterval = 1.0
    /// Coming back has to be sustained, not just glimpsed: this many samples in a
    /// row above presentRSSI, spanning at least returnDwell seconds. A single
    /// stray strong packet used to be enough, and since RSSI swings ~15 dB at the
    /// edge of range, that re-armed the state machine over and over and locked
    /// the screen once per spike.
    var returnSamples = 3
    var returnDwell = 3.0

    /// Set around sleep, because the radio goes down before the screen reports
    /// itself locked and the callback may not be delivered until we wake.
    var systemSleeping = false
    /// True when nothing is at risk: the screen is locked, or we are asleep.
    private var unattended: Bool { Locker.isScreenLocked || systemSleeping }

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
    private var samples: [(rssi: Int, at: Date)] = []

    /// Observed packet arrival rate over the smoothing window. Advertising rate
    /// is the phone's choice, not ours, so this is measured rather than assumed.
    /// True once the smoothing window holds a real average rather than a
    /// cold-start artifact: enough samples, spanning enough of the window.
    private var windowIsRepresentative: Bool {
        guard samples.count >= awaySamples,
              let first = samples.first?.at, let last = samples.last?.at else { return false }
        return last.timeIntervalSince(first) >= smoothingSeconds * 0.75
    }

    private var pastWarmup: Bool {
        if activeTimer != nil { return true }   // connected: readings are trustworthy
        guard let since = monitoringSince else { return false }
        return Date().timeIntervalSince(since) >= warmupSeconds
    }

    private var packetRate: Double {
        guard let first = samples.first?.at, let last = samples.last?.at else { return 0 }
        let span = last.timeIntervalSince(first)
        return span > 0.5 ? Double(samples.count - 1) / span : 0
    }
    private var awayTimer: Timer?
    private var signalTimer: Timer?
    private var activeTimer: Timer?
    private var lastReadAt = Date.distantPast
    private var hasSeenDevice = false
    private var returnStreak = 0
    private var returnStreakStart: Date?
    private var weakStreak = 0
    /// When the smoothed signal first went below the lock threshold and stayed
    /// there. Cleared only by a genuine recovery, not by the hysteresis band.
    private var weakSince: Date?
    /// When this monitor first heard anything, for the warm-up.
    private var monitoringSince: Date?
    /// Time genuinely spent weak. Pauses do not add to it, but do not clear it.
    private var weakAccumulated: TimeInterval = 0
    private var strongSince: Date?
    private var episode: AwayEpisode?
    private var awayStartedAt: Date?
    private var lastHeartbeat = Date.distantPast

    /// One departure, from the first weak reading to whatever ended it. Kept so
    /// that when the phone comes back without a lock having happened, the log
    /// can say exactly how close it got and what interrupted it.
    private struct AwayEpisode {
        let startedAt = Date()
        var pauses = 0
        var weakest = 0
        var longestUnbroken: TimeInterval = 0
        var currentUnbroken: TimeInterval = 0
    }

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

    /// Internal rather than private so the countdown can be driven directly by a
    /// harness — the behaviour it encodes is measured in minutes of walking
    /// about, which is not something to verify by hand.
    func ingest(rssi: Int) {
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
                    let awayFor = awayStartedAt.map { Int(Date().timeIntervalSince($0)) }
                    ActivityLog.shared.record(.ok, "phone_returned",
                        "Phone back in range (\(rssi) dBm, needs \(presentRSSI) dBm for \(returnSamples) readings)",
                        action: "Monitoring re-armed",
                        fields: ["rssi": "\(rssi)", "return_threshold": "\(presentRSSI)",
                                 "away_seconds": "\(awayFor ?? 0)"])
                    awayStartedAt = nil
                    delegate?.monitorDidUpdatePresence(true, reason: "close")
                }
            } else {
                resetReturnStreak()
            }
        }

        let now = Date()
        if monitoringSince == nil { monitoringSince = now }
        samples.append((rssi, now))
        samples.removeAll { now.timeIntervalSince($0.at) > smoothingSeconds }
        // Guard against an unbounded buffer if packets arrive very fast.
        if samples.count > 120 { samples.removeFirst(samples.count - 120) }
        let mean = samples.map(\.rssi).reduce(0, +) / samples.count
        smoothedRSSI = mean
        delegate?.monitorDidUpdateRSSI(mean, active: activeTimer != nil)

        // A periodic trace, so a stretch with no transitions is still
        // reconstructable. Throttled hard: ingest runs several times a second.
        if Date().timeIntervalSince(lastHeartbeat) >= 60 {
            lastHeartbeat = Date()
            ActivityLog.shared.record(.ok, "signal",
                "Signal \(mean) dBm (lock below \(lockRSSI), return above \(presentRSSI))",
                action: present ? "Phone present, nothing to do" : "Phone away",
                fields: ["rssi": "\(mean)", "threshold": "\(lockRSSI)",
                         "present": "\(present)", "mode": activeTimer != nil ? "connected" : "scanning",
                         // How much evidence the smoothed value rests on. If this
                         // is ~1 the window is barely averaging anything.
                         "samples_in_window": "\(samples.count)",
                         "packets_per_sec": String(format: "%.1f", packetRate)])
        }

        // Leaving is judged on the smoothed value, accumulated over time, with
        // hysteresis: the countdown TRIGGERS below lockRSSI but is only released
        // by a recovery above presentRSSI. Releasing at lockRSSI too meant a
        // signal hovering a decibel either side of the line flapped between
        // pause and resume and the countdown never finished — the phone was
        // plainly away, and the screen still did not lock.
        if mean >= presentRSSI {
            weakStreak = 0
            weakSince = nil
            if awayTimer != nil, strongSince == nil { pauseCountdown(mean: mean) }
        } else {
            if mean < lockRSSI {
                weakStreak += 1
                if weakSince == nil { weakSince = Date() }
            }
            if episode != nil, strongSince != nil { resumeCountdown(mean: mean) }
            if var e = episode {
                e.weakest = min(e.weakest, mean)
                episode = e
            }
            if present, awayTimer == nil, let since = weakSince,
               Date().timeIntervalSince(since) >= awaySeconds,
               weakStreak >= awaySamples, windowIsRepresentative {
                if pastWarmup {
                    startCountdown(mean: mean)
                } else {
                    // Logged rather than silent: "it did not lock and said
                    // nothing" is the hardest failure to diagnose afterwards.
                    ActivityLog.shared.record(.expected, "warmup_hold",
                        "Signal is weak (\(mean) dBm) but monitoring only just started",
                        action: "Not locking until connected, or \(Int(warmupSeconds))s after launch",
                        fields: ["rssi": "\(mean)", "lock_threshold": "\(lockRSSI)"])
                }
            }
        }
    }

    private func startCountdown(mean: Int) {
        weakAccumulated = 0
        strongSince = nil
        episode = AwayEpisode(weakest: mean)
        ActivityLog.shared.record(.warn, "countdown_started",
            "Signal weak for \(Int(awaySeconds))s (\(mean) dBm averaged over \(samples.count) readings, lock below \(lockRSSI) dBm)",
            action: "Started \(Int(awayDelay))s countdown — only a recovery above \(presentRSSI) dBm will stop it",
            fields: ["rssi": "\(mean)", "lock_threshold": "\(lockRSSI)",
                     "return_threshold": "\(presentRSSI)", "required": "\(Int(awayDelay))",
                     "samples_in_window": "\(samples.count)"])

        awayTimer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
            self?.advanceCountdown()
        }
        RunLoop.main.add(awayTimer!, forMode: .common)
        delegate?.monitorDidUpdatePending(true)
    }

    private func advanceCountdown() {
        if let since = strongSince {
            // Paused. Held, not reset — but not forever.
            if Date().timeIntervalSince(since) >= blipGrace {
                abandonCountdown("signal recovered for \(Int(blipGrace))s")
            }
            return
        }

        weakAccumulated += tick
        if var e = episode {
            e.currentUnbroken += tick
            e.longestUnbroken = max(e.longestUnbroken, e.currentUnbroken)
            episode = e
        }

        guard weakAccumulated >= awayDelay else { return }
        let held = weakAccumulated
        let pauses = episode?.pauses ?? 0
        stopCountdown()
        present = false
        awayStartedAt = Date()
        ActivityLog.shared.record(.ok, "countdown_complete",
            "Signal stayed weak for the full \(Int(awayDelay))s",
            action: "Declaring phone away",
            fields: ["elapsed": "\(Int(held))", "required": "\(Int(awayDelay))", "pauses": "\(pauses)"])
        delegate?.monitorDidUpdatePresence(false, reason: "away")
    }

    private func pauseCountdown(mean: Int) {
        strongSince = Date()
        episode?.pauses += 1
        episode?.currentUnbroken = 0
        ActivityLog.shared.record(.warn, "countdown_paused",
            "Signal recovered to \(mean) dBm, back above the return threshold \(presentRSSI) dBm",
            action: "Countdown held at \(Int(weakAccumulated))s of \(Int(awayDelay))s for up to \(Int(blipGrace))s",
            fields: ["rssi": "\(mean)", "return_threshold": "\(presentRSSI)",
                     "elapsed": "\(Int(weakAccumulated))", "required": "\(Int(awayDelay))",
                     "pauses": "\(episode?.pauses ?? 0)"])
    }

    private func resumeCountdown(mean: Int) {
        strongSince = nil
        ActivityLog.shared.record(.warn, "countdown_resumed",
            "Signal dropped below the return threshold again (\(mean) dBm)",
            action: "Countdown continues from \(Int(weakAccumulated))s of \(Int(awayDelay))s",
            fields: ["rssi": "\(mean)", "elapsed": "\(Int(weakAccumulated))",
                     "required": "\(Int(awayDelay))"])
    }

    /// Ends a countdown without locking, and says why — the question the log
    /// exists to answer.
    private func abandonCountdown(_ why: String) {
        guard awayTimer != nil else { return }
        let held = weakAccumulated
        let e = episode
        stopCountdown()
        ActivityLog.shared.record(.warn, "countdown_abandoned",
            "Countdown abandoned: \(why)",
            action: "No lock — reached \(Int(held))s of the \(Int(awayDelay))s required",
            fields: ["elapsed": "\(Int(held))", "required": "\(Int(awayDelay))",
                     "pauses": "\(e?.pauses ?? 0)",
                     "longest_unbroken": "\(Int(e?.longestUnbroken ?? 0))",
                     "weakest_rssi": "\(e?.weakest ?? 0)"])
        delegate?.monitorDidUpdatePending(false)
    }

    private func stopCountdown() {
        awayTimer?.invalidate()
        awayTimer = nil
        weakAccumulated = 0
        strongSince = nil
        weakStreak = 0
        weakSince = nil
    }

    private func resetReturnStreak() {
        returnStreak = 0
        returnStreakStart = nil
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
            ActivityLog.shared.record(.warn, "signal_lost",
                "No Bluetooth packets from the phone for \(Int(timeout))s",
                action: self.present ? "Treating as away" : "Already away, no change",
                fields: ["timeout": "\(Int(timeout))", "was_present": "\(self.present)"])
            if self.present {
                self.present = false
                self.awayStartedAt = Date()
                self.delegate?.monitorDidUpdatePresence(false, reason: "lost")
            }
        }
        RunLoop.main.add(signalTimer!, forMode: .common)
    }

    /// Connecting to the phone lets us poll RSSI directly, which is far steadier
    /// than waiting on whatever advertising packets happen to land.
    private func enterActiveMode(_ peripheral: CBPeripheral) {
        guard activeTimer == nil else { return }
        // Worth a line of its own: readings before this point come from
        // advertising packets and run weaker than the truth, which is what the
        // warm-up exists to sit out. This says how long that actually takes.
        ActivityLog.shared.record(.ok, "connected",
            "Connected to the phone, now polling signal directly",
            action: "Readings every \(pollInterval)s instead of whatever advertising lands",
            fields: ["seconds_since_first_reading":
                        monitoringSince.map { String(format: "%.0f", Date().timeIntervalSince($0)) } ?? "0"])
        activeTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
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
        // Every state but poweredOn used to be silent, which meant a denied
        // permission or a switched-off radio looked exactly like "nothing is
        // happening" — the single most confusing way for this app to fail.
        switch central.state {
        case .poweredOn:
            ActivityLog.shared.record(unattended ? .expected : .ok, "bluetooth_ready",
                                      "Bluetooth powered on",
                                      action: "Scanning for the phone")
            startScan()
        case .unauthorized:
            ActivityLog.shared.record(.fail, "bluetooth_unauthorized",
                "Bluetooth permission has not been granted to this app",
                action: "Cannot measure distance — nothing will ever lock",
                fields: ["fix": "System Settings > Privacy & Security > Bluetooth"])
        case .poweredOff:
            // macOS powers the radio down when the machine sleeps, which is
            // most of the times this fires — and the screen is already locked
            // then, so nothing is at risk. Only call it a failure when the
            // screen is up, where it means the user switched Bluetooth off.
            if unattended {
                ActivityLog.shared.record(.expected, "bluetooth_off",
                    "Bluetooth switched off while the Mac was asleep or locked",
                    action: "Monitoring paused until it wakes")
            } else {
                ActivityLog.shared.record(.fail, "bluetooth_off", "Bluetooth is switched off",
                                          action: "Cannot measure distance — nothing will lock")
            }
        case .unsupported:
            ActivityLog.shared.record(.fail, "bluetooth_unsupported",
                                      "This Mac reports no Bluetooth LE support",
                                      action: "Monitoring cannot run")
        default:
            ActivityLog.shared.record(.warn, "bluetooth_state",
                                      "Bluetooth state \(central.state.rawValue)",
                                      action: "Waiting")
        }
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
