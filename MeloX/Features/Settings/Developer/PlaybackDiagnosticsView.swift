import SwiftUI
import UIKit

/// What is playing, where it came from, and how the audio path is set up.
///
/// Read on demand and refreshed while open, so it costs nothing during
/// ordinary playback. The copy button takes the whole report as text, which
/// is the useful form when something goes wrong on a device we cannot see.
struct PlaybackDiagnosticsView: View {
    @Environment(PlayerStore.self) private var player

    @State private var report: PlaybackDiagnostics?
    @State private var didCopy = false

    var body: some View {
        List {
            if let report {
                ForEach(report.sections) { section in
                    Section(section.title) {
                        ForEach(section.rows) { row in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.label)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(row.value)
                                    .font(.footnote.monospaced())
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 1)
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("ui.settings.diagnostics.playback.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    copy()
                } label: {
                    Label(
                        didCopy
                            ? "ui.settings.diagnostics.copied"
                            : "ui.settings.diagnostics.copy",
                        systemImage: didCopy ? "checkmark" : "doc.on.doc"
                    )
                }
                .disabled(report == nil)
            }
        }
        .task { await refresh() }
        .refreshable { await refresh() }
    }

    private func copy() {
        guard let report else { return }
        UIPasteboard.general.string = report.text
        withAnimation(.snappy(duration: 0.2)) { didCopy = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.snappy(duration: 0.2)) { didCopy = false }
        }
    }

    /// Refreshes while the page is open: the position and the decks move.
    private func refresh() async {
        report = player.playbackDiagnostics()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            report = player.playbackDiagnostics()
        }
    }
}
