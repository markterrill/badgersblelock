import Cocoa

/// A plain table of what the app has done. The point is not to look at it every
/// day — it is to have something concrete to hand over when someone says "it
/// didn't lock", instead of trying to remember what happened.
final class ActivityLogWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private var table = NSTableView()
    private var events: [ActivityEvent] = []
    /// Supplies the settings block at the top of a copied report.
    private let header: () -> [String: String]

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init(header: @escaping () -> [String: String]) {
        self.header = header
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 460),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Badgers BLE Lock — Activity"
        super.init(window: window)
        build(in: window)
        NotificationCenter.default.addObserver(
            forName: ActivityLog.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.reload() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build(in window: NSWindow) {
        let columns: [(String, String, CGFloat)] = [
            ("time", "Time", 74), ("level", "", 28),
            ("description", "What happened", 420), ("action", "What the app did", 300),
        ]
        for (id, title, width) in columns {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 20

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // The copy button is the actual deliverable: it puts settings, machine
        // capabilities and recent history on the clipboard in one go, so nobody
        // has to be talked through collecting them.
        let copy = NSButton(title: "Copy Diagnostics", target: self, action: #selector(copyReport))
        let reveal = NSButton(title: "Show Log File", target: self, action: #selector(revealFile))
        let note = NSTextField(labelWithString: "Paste the copied report into Claude to work out why a lock did not happen.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        for v in [copy, reveal, note] { v.translatesAutoresizingMaskIntoConstraints = false }

        let content = window.contentView!
        [scroll, copy, reveal, note].forEach { content.addSubview($0) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: copy.topAnchor, constant: -10),
            copy.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            copy.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            reveal.leadingAnchor.constraint(equalTo: copy.trailingAnchor, constant: 8),
            reveal.centerYAnchor.constraint(equalTo: copy.centerYAnchor),
            note.leadingAnchor.constraint(equalTo: reveal.trailingAnchor, constant: 12),
            note.centerYAnchor.constraint(equalTo: copy.centerYAnchor),
        ])
    }

    func present() {
        reload()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
    }

    private func reload() {
        // Newest first: when something has just gone wrong, it is the top line.
        events = ActivityLog.shared.events.reversed()
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { events.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let e = events[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "time":        text = Self.stamp.string(from: e.at)
        case "level":       text = e.level.symbol
        case "description": text = e.description
        default:            text = e.action
        }
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.lineBreakMode = .byTruncatingTail
        if e.level == .fail { field.textColor = .systemRed }
        if e.level == .expected { field.textColor = .secondaryLabelColor }
        return field
    }

    @objc private func copyReport() {
        let report = ActivityLog.shared.diagnosticsReport(header: header())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    @objc private func revealFile() {
        NSWorkspace.shared.selectFile(ActivityLog.shared.logFilePath,
                                      inFileViewerRootedAtPath: "")
    }
}
