import SwiftUI

struct MainPanelView: View {
    @Environment(ModuleRegistry.self) private var registry
    @Environment(AccessibilityPermissionManager.self) private var permissionManager
    @Environment(LocalizationService.self) private var localizationService
    @Environment(PanelConfiguration.self) private var panelConfig

    /// Reports this view's laid-out size so the enclosing NSHostingView can follow it.
    ///
    /// An NSMenuItem's custom view keeps whatever frame it was given, so a module
    /// toggled ON — which reveals its settings row and grows the content — would
    /// otherwise push the Settings/Quit rows out of view until the panel was closed
    /// and reopened.
    var onContentSizeChange: ((CGSize) -> Void)? = nil

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
        .frame(width: MainPanelSizing.width)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            onContentSizeChange?(size)
        }
        .onAppear {
            // Re-check permission every time the panel opens
            permissionManager.checkPermission()
            // Re-sync toggles with real system state (covers external changes
            // like Cmd+Opt+D or System Settings while the app was running)
            registry.syncModulesFromSystem()
        }
    }
}
