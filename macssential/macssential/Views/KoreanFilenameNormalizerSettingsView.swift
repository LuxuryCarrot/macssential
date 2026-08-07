import AppKit
import SwiftUI

struct KoreanFilenameNormalizerSettingsView: View {
    @Bindable var module: KoreanFilenameNormalizerModule

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(module.watchedFolders, id: \.self) { folder in
                HStack(spacing: 4) {
                    Text(displayPath(folder))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(action: { removeFolder(folder) }) {
                        Image(systemName: "minus.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "module.kfn.remove_folder"))
                }
            }

            Button(String(localized: "module.kfn.add_folder")) {
                addFolder()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundColor(.accentColor)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            guard !module.watchedFolders.contains(url.path) else { return }
            module.watchedFolders.append(url.path)
        }
    }

    private func removeFolder(_ path: String) {
        module.watchedFolders.removeAll { $0 == path }
    }

    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
