import Foundation

/// Read-only facts about the song playing and the audio path under it.
///
/// Everything here comes from what the app already knows: the catalog entry,
/// the stream a source delivered, the playback engine, and the audio session.
/// It exists to answer "what exactly is playing, and through what" when a
/// listener reports a problem that cannot be reproduced elsewhere.
nonisolated struct PlaybackDiagnostics: Sendable {
    struct Row: Identifiable, Sendable {
        let label: String
        let value: String

        var id: String { label }
    }

    struct Section: Identifiable, Sendable {
        let title: String
        let rows: [Row]

        var id: String { title }
    }

    let sections: [Section]
    let copiedAt: Date

    /// The whole report as plain text, for sharing a problem.
    var text: String {
        var lines = [
            "MeloX playback diagnostics",
            "Captured: \(Self.stamp(copiedAt))",
        ]
        for section in sections {
            lines.append("")
            lines.append("[\(section.title)]")
            for row in section.rows {
                lines.append("\(row.label): \(row.value)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// A second-resolution timestamp, without depending on the locale.
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// A source address reduced to what identifies the file: its host and the
    /// start of its name. The query carries a signed key and is dropped.
    static func maskedAddress(_ url: URL) -> String {
        if url.isFileURL { return "local file" }
        let host = url.host ?? "?"
        let name = url.lastPathComponent
        let prefix = name.prefix(4)
        let ext = url.pathExtension.lowercased()
        let file = ext.isEmpty ? "\(prefix)…" : "\(prefix)….\(ext)"
        return "\(host)/…/\(file)"
    }

    static func bytes(_ value: Int64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var size = Double(value)
        var unit = 0
        while size >= 1024, unit < units.count - 1 {
            size /= 1024
            unit += 1
        }
        let number = unit == 0
            ? String(Int(size))
            : String(format: "%.1f", size)
        return "\(number) \(units[unit])"
    }
}
