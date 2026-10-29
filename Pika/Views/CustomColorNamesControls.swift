import Defaults
import SwiftUI
import UniformTypeIdentifiers

struct CustomColorNamesControls: View {
    @ObservedObject private var manager = ColorNamesManager.shared
    @Default(.useCustomColorNames) private var useCustomColorNames
    @State private var importing = false
    @State private var editingURL = false
    @State private var urlText = ""
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Import JSON…") {
                    importError = nil
                    importing = true
                }
                Button("Load URL…") {
                    importError = nil
                    urlText = manager.customList?.sourceURL?.absoluteString ?? ""
                    editingURL.toggle()
                }
                if useCustomColorNames, manager.customList?.sourceURL != nil {
                    Spacer(minLength: 0)
                    Button("Refresh") { manager.refreshAll() }
                        .disabled(manager.isLoadingCustom)
                }
            }
            .controlSize(.small)

            if editingURL {
                HStack {
                    TextField("https://example.com/colors.json", text: $urlText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Colour names JSON URL")
                        .onSubmit { loadURL() }
                    Button("Load", action: loadURL)
                        .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || manager.isLoadingCustom)
                }
                Text("Use a JSON object with a colors array. Each colour needs name and hex (#RRGGBB).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if useCustomColorNames, let list = manager.customList {
                if let url = list.sourceURL {
                    Text(url.absoluteString)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    Text("Imported copy. Import the file again to update its colours.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("\(list.colors.count) colour names. The nearest colour name is shown.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = importError ?? manager.lastErrorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(String(localized: "Colour list error: ") + error)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case let .success(url): manager.importCustomFile(url)
            case let .failure(error): importError = error.localizedDescription
            }
        }
    }

    private func loadURL() {
        guard !manager.isLoadingCustom else { return }
        importError = nil
        manager.loadCustomURL(urlText)
    }
}
