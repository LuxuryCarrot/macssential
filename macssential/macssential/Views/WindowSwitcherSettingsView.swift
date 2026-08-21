import SwiftUI

struct WindowSwitcherSettingsView: View {
    @Bindable var module: WindowSwitcherModule

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let warning = module.secureInputWarning {
                warningRow(warning)
            }
            if module.tapCreationFailed {
                warningRow(String(localized: "module.window_switcher.tap_failed"))
            }

            Text(String(localized: "module.window_switcher.hint"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Shown only while the permission is missing, and never acted on by
            // itself: reading the status uses the non-prompting preflight check, so
            // merely opening the panel cannot trigger the TCC alert. The whole row
            // disappears once granted rather than becoming a persistent nag.
            if !module.screenRecordingGranted {
                Text(String(localized: "module.window_switcher.screen_recording_hint"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(String(localized: "module.window_switcher.screen_recording_button")) {
                    module.requestScreenRecordingPermission()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.accentColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func warningRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundColor(.orange)
            Text(message)
                .font(.caption)
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
