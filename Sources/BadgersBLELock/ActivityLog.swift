import Foundation
import os

/// What happened, what the app did about it, and whether that was a problem.
///
/// This exists because the unified log is not usable for this app's own
/// messages: `NSLog` routes through Foundation, which marks the whole message
/// private, so every line reads `<private>` in `log show`. Events here are
/// therefore kept in a file the user can read and paste, and mirrored to
/// os.Logger with explicit public privacy as a backstop.
struct ActivityEvent {
    enum Level: String {
        case ok, warn, fail
        /// Worth recording, but not a fault: the radio going away because the
        /// Mac slept, for instance. Red here would train the eye to ignore red.
        case expected

        /// Traffic light. Nothing else in the row is colour-coded, so this is
        /// what the eye lands on when scanning for the failure.
        var symbol: String {
            switch self {
            case .ok:       return "🟢"
            case .warn:     return "🟡"
            case .fail:     return "🔴"
            case .expected: return "⚪️"
            }
        }
    }

    let at: Date
    let level: Level
    /// Stable machine-readable key (`countdown_paused`), so analysis can group
    /// and count events without parsing prose.
    let event: String
    /// What happened, in the user's terms, with the numbers that explain it.
    let description: String
    /// What the app did in response — the half that says whether it locked.
    let action: String
    /// Structured values behind the prose: rssi, thresholds, elapsed seconds.
    let fields: [String: String]

    var fieldText: String {
        fields.keys.sorted().map { "\($0)=\(fields[$0] ?? "")" }.joined(separator: " ")
    }
}

final class ActivityLog {
    static let shared = ActivityLog()

    /// Enough to cover a working day of walking about without unbounded growth.
    private let capacity = 500
    private(set) var events: [ActivityEvent] = []

    // A run of identical events collapses to its first and last line. The
    // 60-second heartbeat would otherwise bury the handful of lines that
    // actually explain a failure, in the file and in the window alike.
    private var runKey: String?
    private var runCount = 0
    private var runStart = Date()
    private var hasTail = false
    private var pendingTailLine: String?

    private let logger = Logger(subsystem: "local.badgersblelock", category: "activity")
    private let queue = DispatchQueue(label: "local.badgersblelock.activity")
    private let fileURL: URL?

    /// Posted when a new event lands, so an open window can refresh itself.
    static let didChange = Notification.Name("ActivityLogDidChange")

    private init() {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("Logs/BadgersBLELock", isDirectory: true)
        if let dir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            fileURL = dir.appendingPathComponent("activity.log")
        } else {
            fileURL = nil
        }
    }

    func record(_ level: ActivityEvent.Level,
                _ event: String,
                _ description: String,
                action: String,
                fields: [String: String] = [:]) {
        let incoming = ActivityEvent(at: Date(), level: level, event: event,
                                     description: description, action: action, fields: fields)
        let key = "\(event)|\(level.rawValue)|\(fields["reason"] ?? "")"

        if key == runKey {
            // Same thing again. Keep the first line, and keep exactly one
            // trailing line that carries the latest values and the duration.
            runCount += 1
            let tail = summarised(incoming)
            if hasTail {
                events[events.count - 1] = tail
            } else {
                events.append(tail)
                hasTail = true
            }
            // Held back from the file until the run ends, so the file gets the
            // same first-and-last pair rather than one line per repeat.
            pendingTailLine = line(for: tail)
            NotificationCenter.default.post(name: Self.didChange, object: nil)
            return
        }

        flushPendingTail()
        runKey = key
        runCount = 1
        runStart = incoming.at
        hasTail = false

        events.append(incoming)
        if events.count > capacity { events.removeFirst(events.count - capacity) }
        emit(incoming)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private func summarised(_ e: ActivityEvent) -> ActivityEvent {
        let elapsed = e.at.timeIntervalSince(runStart)
        let span = elapsed < 90
            ? "\(max(1, Int(elapsed.rounded()))) seconds"
            : "\(Int((elapsed / 60).rounded())) minutes"
        var fields = e.fields
        fields["repeats"] = "\(runCount)"
        fields["repeat_span_seconds"] = "\(Int(elapsed))"
        return ActivityEvent(at: e.at, level: e.level, event: e.event,
                             description: "\(e.description) (repeated \(runCount) times over the last \(span))",
                             action: e.action, fields: fields)
    }

    /// Writes the closing line of a collapsed run. Called when a different event
    /// arrives, and at quit — otherwise a run still in progress is missing its
    /// summary from the file.
    func flushPendingTail() {
        guard let line = pendingTailLine else { return }
        append(line)
        pendingTailLine = nil
    }

    private func emit(_ e: ActivityEvent) {
        // Explicitly public: os.Logger redacts interpolated values by default,
        // which is how the previous logging ended up unreadable.
        logger.log(level: e.level == .fail ? .error : .default,
                   "\(e.event, privacy: .public) \(e.description, privacy: .public) — \(e.action, privacy: .public) \(e.fieldText, privacy: .public)")
        append(line(for: e))
    }

    private func line(for e: ActivityEvent) -> String {
        let stamp = ISO8601DateFormatter().string(from: e.at)
        return "\(stamp) [\(e.level.rawValue.uppercased())] \(e.event) | \(e.description) | \(e.action) | \(e.fieldText)\n"
    }

    /// Written at every launch. The log is meant to be handed to someone — or
    /// something — that has never seen the source, so it carries its own format
    /// description and the settings that decide every later line.
    func startSession(_ header: [String: String]) {
        trimFile()
        var text = "\n"
        text += "\(Self.sessionMarker)\(ISO8601DateFormatter().string(from: Date())) ===\n"
        text += "# format: <iso8601> [LEVEL] <event> | <description> | <action> | <key=value ...>\n"
        text += "# LEVEL: OK = normal, WARN = something delayed or paused the lock, FAIL = the lock did not happen\n"
        text += "# LEVEL: EXPECTED = routine and not a fault, e.g. the radio going down while the Mac sleeps\n"
        text += "# rssi values are dBm; less negative is closer. elapsed/required are seconds.\n"
        for key in header.keys.sorted() { text += "# \(key)=\(header[key] ?? "")\n" }
        append(text)
    }

    /// How much history the file keeps. Long enough to cover a weekend's worth
    /// of "it did not lock on Friday", short enough that the file stays small
    /// and pasteable.
    private let retentionDays = 3.0

    /// Drops whole sessions older than `retentionDays`, at launch only. Runs on
    /// the same serial queue as `append`, so the header written immediately
    /// afterwards lands after the trim rather than inside it.
    ///
    /// Whole sessions, rather than individual lines: a session is only
    /// intelligible together with the header listing the settings that produced
    /// it, and a session that began four days ago but is still running is
    /// current, not stale. A block is kept when its NEWEST line is recent.
    private func trimFile() {
        guard let fileURL else { return }
        queue.async {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
            let cutoff = Date().addingTimeInterval(-self.retentionDays * 86_400)

            var blocks: [[String]] = []
            for line in text.components(separatedBy: "\n") {
                if line.hasPrefix(Self.sessionMarker) || blocks.isEmpty { blocks.append([]) }
                blocks[blocks.count - 1].append(line)
            }
            let kept = blocks.filter { block in
                // A block with no parseable timestamp is kept: it cannot be
                // shown to be old, and silently dropping it would lose context.
                guard let newest = block.compactMap(Self.timestamp).max() else { return true }
                return newest >= cutoff
            }
            guard kept.count < blocks.count else { return }

            let dropped = blocks.count - kept.count
            let note = "# (\(dropped) session\(dropped == 1 ? "" : "s") older than "
                + "\(Int(self.retentionDays)) days trimmed at launch)\n"
            let body = kept.map { $0.joined(separator: "\n") }.joined(separator: "\n")
            try? (note + body).write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    private static let sessionMarker = "=== session start "

    /// The timestamp a log line carries, in either of the two positions the
    /// format puts one.
    private static func timestamp(_ line: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if line.hasPrefix(sessionMarker) {
            return formatter.date(from: String(line.dropFirst(sessionMarker.count).prefix(20)))
        }
        if line.hasPrefix("20") { return formatter.date(from: String(line.prefix(20))) }
        return nil
    }

    /// Appended off the main thread: this is called from the RSSI path, which
    /// runs often enough that a synchronous write would be felt.
    private func append(_ text: String) {
        guard let fileURL else { return }
        queue.async {
            guard let data = text.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    var logFilePath: String { fileURL?.path ?? "(unavailable)" }

    /// Everything someone would otherwise have to be talked through gathering,
    /// in one paste: the settings that decide behaviour, the capabilities that
    /// silently differ between machines, and the recent history.
    func diagnosticsReport(header: [String: String]) -> String {
        var out = "# Badgers BLE Lock diagnostics\n"
        out += "generated: \(ISO8601DateFormatter().string(from: Date()))\n"
        for key in header.keys.sorted() { out += "\(key): \(header[key] ?? "")\n" }
        out += "\n# Activity (most recent last)\n"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for e in events.suffix(120) {
            out += "\(formatter.string(from: e.at))  \(e.level.symbol)  \(e.description) — \(e.action)\n"
        }
        return out
    }
}
