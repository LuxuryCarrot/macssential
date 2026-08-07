import SwiftUI

struct AccessibilityOnboardingView: View {
    let permissionManager: AccessibilityPermissionManager
    /// Reference to the hosting NSWindow so we can close it directly.
    /// When presented via AppDelegate.presentOnboardingWindow(), this is set.
    /// Environment dismiss is unreliable for standalone NSWindows from NSMenu context.
    weak var hostWindow: NSWindow?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if permissionManager.needsReauthorization {
                // Re-authorization after update/rebuild
                Text("Accessibility Permission Lost")
                    .font(.headline)
                    .padding(.bottom, 8)

                Text("macssential was updated and needs Accessibility permission again. This is a macOS requirement when the app binary changes.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 16)

                stepRow(number: "1", text: Text("Open ") + Text("System Settings").bold() + Text(" > ") + Text("Privacy & Security").bold() + Text(" > ") + Text("Accessibility").bold())
                    .padding(.bottom, 12)

                stepRow(number: "2", text: Text("Find ") + Text("macssential").bold() + Text(" — toggle it ") + Text("off").bold() + Text(" then ") + Text("on").bold() + Text(" again"))
                    .padding(.bottom, 12)

                stepRow(number: "3", text: Text("If not listed, click ") + Text("+").bold() + Text(" and add macssential from Applications"))
            } else {
                // First-time setup
                Text("Accessibility Permission Required")
                    .font(.headline)
                    .padding(.bottom, 16)

                stepRow(number: "1", text: Text("Open ") + Text("System Settings").bold() + Text(" on your Mac"))
                    .padding(.bottom, 12)

                stepRow(number: "2", text: Text("Go to ") + Text("Privacy & Security").bold() + Text(" > ") + Text("Accessibility").bold())
                    .padding(.bottom, 12)

                stepRow(number: "3", text: Text("Find ") + Text("macssential").bold() + Text(" in the list and enable it"))
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Not Now") {
                    closeWindow()
                }
                .buttonStyle(.plain)

                Button("Open System Settings") {
                    // Trigger system permission dialog for THIS binary,
                    // then also open the Settings pane for manual add
                    permissionManager.promptSystemPermission()
                    permissionManager.openSystemSettings()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
        .frame(width: 400)
        .onAppear { permissionManager.startPolling(interval: 1.0) }
        .onDisappear { permissionManager.stopPolling() }
        .onChange(of: permissionManager.isGranted) { _, granted in
            if granted { closeWindow() }
        }
    }

    private func closeWindow() {
        if let hostWindow {
            hostWindow.close()
        } else {
            dismiss()
        }
    }

    // MARK: - Step Row Helper

    private func stepRow(number: String, text: Text) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(number)
                .font(.body)
                .fontWeight(.semibold)
                .foregroundColor(.accentColor)
                .frame(width: 24, alignment: .leading)

            text
                .font(.body)
                .foregroundColor(.primary)
        }
    }
}
