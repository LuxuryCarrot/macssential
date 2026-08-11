import SwiftUI

struct MainPanelView: View {
    @Environment(ModuleRegistry.self) private var registry
    @Environment(AccessibilityPermissionManager.self) private var permissionManager
    @Environment(LocalizationService.self) private var localizationService
    @Environment(PanelConfiguration.self) private var panelConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(registry.modules.filter {
                panelConfig.isVisible($0.id) && $0.isRelevant(to: localizationService.currentLanguage)
            }, id: \.id) { module in
                VStack(spacing: 0) {
                    FeatureRowView(
                        module: module,
                        permissionManager: module.requiresAccessibilityPermission ? permissionManager : nil,
                        registry: registry,
                        usesPanelToggleStyle: true
                    )
                    if let settingsView = module.settingsView, module.isEnabled {
                        settingsView
                    }
                }
            }

            Divider()
                .padding(.vertical, 4)

            Button(action: {
                if let appDelegate = NSApp.delegate as? AppDelegate {
                    appDelegate.showSettingsWindow()
                }
            }) {
                Label(String(localized: "panel.settings"), systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)

            Button(String(localized: "panel.quit")) {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .padding(.vertical, 8)
        .frame(width: 280)
        .onAppear {
            // Re-check permission every time the panel opens
            permissionManager.checkPermission()
            // Re-sync toggles with real system state (covers external changes
            // like Cmd+Opt+D or System Settings while the app was running)
            registry.syncModulesFromSystem()
        }
    }
}
