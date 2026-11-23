import SwiftUI
import UniformTypeIdentifiers

struct LXSourceSettingsView: View {
    @Environment(LXSourceStore.self) private var store
    @State private var input = ""
    @State private var isFileImporterPresented = false
    @State private var showsError = false

    var body: some View {
        List {
            Section(L10n.string("ui.sources.section.add")) {
                TextField(
                    L10n.string("ui.sources.url.placeholder"),
                    text: $input,
                    axis: .vertical
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .lineLimit(1...3)

                HStack {
                    Button(L10n.string("ui.sources.action.add_url")) {
                        addURL()
                    }
                    Spacer()
                    Button(L10n.string("ui.sources.action.add_list")) {
                        addList()
                    }
                }

                Button(L10n.string("ui.sources.action.add_file")) {
                    isFileImporterPresented = true
                }
            }

            Section(L10n.string("ui.sources.section.installed")) {
                if store.sources.isEmpty {
                    Text(L10n.string("ui.sources.empty"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.sources) { source in
                        row(source)
                    }
                }
            }

            Section {
                Text(L10n.string("ui.sources.security"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L10n.string("ui.settings.sources.title"))
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if store.isWorking {
                ProgressView(L10n.string("ui.sources.working"))
                    .padding(20)
                    .background(.regularMaterial, in: .rect(cornerRadius: 16))
            }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.javaScript, .plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await store.addScriptFile(url) }
            case .failure(let error):
                store.errorMessage = error.localizedDescription
            }
        }
        .alert(
            L10n.string("ui.sources.error"),
            isPresented: $showsError
        ) {
            Button("ui.common.ok", role: .cancel) {
                store.errorMessage = nil
            }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .onChange(of: store.errorMessage) { _, newValue in
            showsError = newValue != nil
        }
    }

    private func row(_ source: LXSource) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: source.name)
                        .font(.headline)
                    Text(verbatim: subtitle(for: source))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { source.isEnabled },
                        set: { store.setEnabled(source, isEnabled: $0) }
                    )
                )
                .labelsHidden()
            }

            if let qualities = source.qqCapability?.qualitys,
               !qualities.isEmpty {
                Text(
                    L10n.format(
                        "ui.sources.qualities",
                        qualities.joined(separator: ", ")
                    )
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            if let error = source.lastError, !error.isEmpty {
                Text(verbatim: error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 16) {
                Button(L10n.string("ui.sources.action.move_up")) {
                    store.move(source, offset: -1)
                }
                .disabled(source.priority == 0)

                Button(L10n.string("ui.sources.action.move_down")) {
                    store.move(source, offset: 1)
                }
                .disabled(source.priority == store.sources.count - 1)

                Button(L10n.string("ui.sources.action.refresh")) {
                    Task { await store.refresh(source) }
                }

                Spacer()

                Button(
                    L10n.string("ui.sources.action.delete"),
                    role: .destructive
                ) {
                    store.remove(source)
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(.vertical, 4)
    }

    private func subtitle(for source: LXSource) -> String {
        var parts: [String] = []
        if !source.version.isEmpty {
            parts.append(
                L10n.format("ui.sources.version", source.version)
            )
        }
        parts.append(
            source.scriptURL == nil
                ? L10n.string("ui.sources.local")
                : source.maskedScriptURL
        )
        return parts.joined(separator: " · ")
    }

    private func addURL() {
        let value = input
        Task {
            await store.addScriptURL(value)
            if store.errorMessage == nil {
                input = ""
            }
        }
    }

    private func addList() {
        let value = input
        Task {
            await store.addSourceList(value)
            if store.errorMessage == nil {
                input = ""
            }
        }
    }
}
