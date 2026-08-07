import AppKit
import SwiftUI

struct ScreenshotAutoCopySettingsView: View {
    @Bindable var module: ScreenshotAutoCopyModule

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(String(localized: "module.screenshot_auto_copy.also_save_to_folder"),
                   isOn: $module.alsoSaveToFolder)
                .toggleStyle(.checkbox)
                .font(.caption)

            if module.alsoSaveToFolder {
                HStack(spacing: 6) {
                    Text(module.saveFolder)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(String(localized: "module.screenshot_auto_copy.choose_folder")) {
                        chooseSaveFolder()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundColor(.accentColor)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: module.saveFolder)
        if panel.runModal() == .OK, let url = panel.url {
            module.saveFolder = url.path
            syncToMacOSScreenshotLocation(url.path)
        }
    }

    private func syncToMacOSScreenshotLocation(_ path: String) {
        let defaults = Process()
        defaults.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        defaults.arguments = ["write", "com.apple.screencapture", "location", path]
        try? defaults.run()
        defaults.waitUntilExit()
        let killall = Process()
        killall.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killall.arguments = ["SystemUIServer"]
        try? killall.run()
    }
}
