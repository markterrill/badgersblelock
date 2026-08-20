import Cocoa

/// Narrows a room full of Bluetooth devices down to one phone by asking the user
/// to toggle Bluetooth off and on. Each cycle keeps only the devices whose
/// presence tracked the toggle, which converges fast even in a busy office.
final class PairingWizard: NSWindowController {

    private enum Step {
        case intro
        case turnOff
        case turnOn
    }

    private let monitor: ProximityMonitor
    private let onComplete: (UUID) -> Void

    private var step: Step = .intro
    private var cycle = 0
    private var candidates: Set<UUID> = []
    private var lastOffSet: Set<UUID> = []
    private var sampleTimer: Timer?
    private var warning: String?

    /// How long to listen after each toggle. iPhones advertise every couple of
    /// seconds, so this is generous enough to avoid false disappearances.
    private let sampleSeconds = 10

    // UI
    private let headline = NSTextField(labelWithString: "")
    private let instruction = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let candidateStack = NSStackView()
    private let primaryButton = NSButton(title: "Start", target: nil, action: nil)
    private let useButton = NSButton(title: "Use Selected Device", target: nil, action: nil)
    private var selectedUUID: UUID?

    init(monitor: ProximityMonitor, onComplete: @escaping (UUID) -> Void) {
        self.monitor = monitor
        self.onComplete = onComplete
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 480),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Pair Your Phone"
        super.init(window: window)
        buildUI()
        render()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func present() {
        monitor.pairingActive = true
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
    }

    private func finish(_ uuid: UUID?) {
        sampleTimer?.invalidate()
        monitor.pairingActive = false
        if let uuid { onComplete(uuid) }
        close()
    }

    // MARK: - UI

    private func buildUI() {
        headline.font = .systemFont(ofSize: 15, weight: .semibold)
        instruction.font = .systemFont(ofSize: 12)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        progress.style = .bar
        progress.isIndeterminate = false
        progress.isHidden = true

        candidateStack.orientation = .vertical
        candidateStack.alignment = .leading
        candidateStack.spacing = 4
        candidateStack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = candidateStack
        scroll.translatesAutoresizingMaskIntoConstraints = false
        candidateStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            candidateStack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            candidateStack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            candidateStack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])

        primaryButton.target = self
        primaryButton.action = #selector(primaryTapped)
        primaryButton.keyEquivalent = "\r"
        useButton.target = self
        useButton.action = #selector(useTapped)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        let buttons = NSStackView(views: [cancel, NSView(), useButton, primaryButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let root = NSStackView(views: [headline, instruction, scroll, progress, statusLabel, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView = root
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window!.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window!.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window!.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window!.contentView!.bottomAnchor),
            instruction.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            progress.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36),
        ])
    }

    private func render() {
        switch step {
        case .intro:
            headline.stringValue = "Step 1 — Bluetooth on"
            instruction.stringValue = """
                Make sure Bluetooth is ON on your iPhone and that the phone is \
                already paired with this Mac, then bring it near the keyboard.

                Pairing matters: an unpaired iPhone changes its Bluetooth identity \
                every few minutes, so it can't be tracked reliably.
                """
            primaryButton.title = "Start Listening"
        case .turnOff:
            headline.stringValue = "Step \(2 + cycle * 2) — Turn Bluetooth OFF"
            instruction.stringValue = """
                Turn Bluetooth OFF on your iPhone (Settings › Bluetooth, or \
                Control Centre — but Settings is more reliable), then click Continue.

                Whichever devices go quiet are the ones still in the running.
                """
            primaryButton.title = "Continue"
        case .turnOn:
            headline.stringValue = "Step \(3 + cycle * 2) — Turn Bluetooth back ON"
            instruction.stringValue = """
                Turn Bluetooth back ON on your iPhone, then click Continue.

                Only devices that reappeared right now stay on the list.
                """
            primaryButton.title = "Continue"
        }
        renderCandidates()
    }

    private func candidateList() -> [DiscoveredDevice] {
        let pool = candidates.isEmpty
            ? Array(monitor.discovered.values)
            : monitor.discovered.values.filter { candidates.contains($0.uuid) }
        return pool.sorted {
            let (a, b) = (NameMatch.score(deviceName: $0.name), NameMatch.score(deviceName: $1.name))
            return a == b ? $0.rssi > $1.rssi : a > b
        }
    }

    private func renderCandidates() {
        candidateStack.arrangedSubviews.forEach {
            candidateStack.removeArrangedSubview($0); $0.removeFromSuperview()
        }

        let list = candidateList()
        let guess = NameMatch.bestGuess(among: list.map { (id: $0.uuid, name: $0.name) })
        if selectedUUID == nil || !list.contains(where: { $0.uuid == selectedUUID }) {
            selectedUUID = guess ?? (list.count == 1 ? list[0].uuid : nil)
        }

        if list.isEmpty {
            candidateStack.addArrangedSubview(
                NSTextField(labelWithString: "No devices in range yet — listening…"))
        }

        for device in list {
            let likely = device.uuid == guess
            let title = likely
                ? "\(device.name)   (\(device.rssi) dBm)   ★ likely yours"
                : "\(device.name)   (\(device.rssi) dBm)"
            let radio = NSButton(radioButtonWithTitle: title, target: self, action: #selector(radioTapped(_:)))
            radio.identifier = NSUserInterfaceItemIdentifier(device.uuid.uuidString)
            radio.state = device.uuid == selectedUUID ? .on : .off
            if likely {
                radio.attributedTitle = NSAttributedString(
                    string: title,
                    attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
            }
            candidateStack.addArrangedSubview(radio)
        }

        let remaining = list.count
        if let warning {
            statusLabel.stringValue = warning
            statusLabel.textColor = .systemOrange
        } else if candidates.isEmpty {
            statusLabel.stringValue = "\(remaining) device(s) in range. " +
                "Pick yours now if you recognise it, or keep narrowing."
            statusLabel.textColor = .secondaryLabelColor
        } else {
            statusLabel.stringValue = "\(remaining) candidate(s) left after \(cycle + 1) cycle(s)."
            statusLabel.textColor = remaining == 1 ? .systemGreen : .secondaryLabelColor
        }
        useButton.isEnabled = selectedUUID != nil
    }

    // MARK: - Sampling

    private func sample(then completion: @escaping (Set<UUID>) -> Void) {
        let windowStart = Date()
        var remaining = sampleSeconds
        primaryButton.isEnabled = false
        useButton.isEnabled = false
        progress.isHidden = false
        progress.minValue = 0
        progress.maxValue = Double(sampleSeconds)
        progress.doubleValue = 0

        sampleTimer?.invalidate()
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { return }
            remaining -= 1
            self.progress.doubleValue = Double(self.sampleSeconds - remaining)
            self.statusLabel.stringValue = "Listening… \(remaining)s"
            self.statusLabel.textColor = .secondaryLabelColor
            if remaining <= 0 {
                timer.invalidate()
                self.progress.isHidden = true
                self.primaryButton.isEnabled = true
                let seen = Set(self.monitor.devicesSeen(since: windowStart).map(\.uuid))
                completion(seen)
            }
        }
        RunLoop.main.add(sampleTimer!, forMode: .common)
    }

    // MARK: - Actions

    @objc private func radioTapped(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let uuid = UUID(uuidString: raw) else { return }
        selectedUUID = uuid
        useButton.isEnabled = true
    }

    @objc private func useTapped() {
        finish(selectedUUID)
    }

    @objc private func cancelTapped() {
        finish(nil)
    }

    @objc private func primaryTapped() {
        warning = nil
        switch step {
        case .intro:
            sample { [weak self] seen in
                guard let self else { return }
                // Baseline: everything advertising while the phone is on.
                self.candidates = seen
                self.step = .turnOff
                self.render()
            }

        case .turnOff:
            sample { [weak self] seen in
                guard let self else { return }
                self.lastOffSet = seen
                let survivors = self.candidates.subtracting(seen)
                if survivors.isEmpty {
                    self.warning = "Nothing disappeared — is Bluetooth really off on the phone? " +
                        "Keeping the previous list and trying again."
                } else {
                    self.candidates = survivors
                }
                self.step = .turnOn
                self.render()
            }

        case .turnOn:
            sample { [weak self] seen in
                guard let self else { return }
                // Devices that were absent while off and are present now.
                let reappeared = seen.subtracting(self.lastOffSet)
                let intersection = self.candidates.intersection(reappeared)
                if intersection.isEmpty {
                    if reappeared.isEmpty {
                        self.warning = "Nothing came back — is Bluetooth on again? Try this step once more."
                    } else {
                        // The phone came back under a new identity, which means it
                        // isn't paired with this Mac. Restart tracking from what
                        // just appeared, and say so.
                        self.candidates = reappeared
                        self.warning = "Your phone reappeared with a new Bluetooth identity, so it is " +
                            "not paired with this Mac. Pair it in System Settings › Bluetooth, " +
                            "otherwise it can't be tracked reliably."
                    }
                } else {
                    self.candidates = intersection
                }
                self.cycle += 1
                self.step = .turnOff
                self.render()
            }
        }
    }
}
