import SwiftUI

struct FeatureRowView: View {
    let module: any FeatureModule
    var permissionManager: AccessibilityPermissionManager? = nil
    var registry: ModuleRegistry? = nil
    /// When true (NSMenu panel context), use PanelSwitchToggleStyle with
    /// explicit colors — the native `.switch` desaturates inside NSMenu-hosted
    /// views because the menu window is never key. Default false keeps the
    /// native style for real-window contexts (Settings Modules tab).
    var usesPanelToggleStyle: Bool = false

    private var isEnabledBinding: Binding<Bool> {
        Binding(
            get: { module.isEnabled },
            set: { newValue in
                module.isEnabled = newValue
                if newValue {
                    registry?.disableConflicting(with: module.id)
                }
            }
        )
    }

    /// Whether this module needs Accessibility permission but doesn't have it yet.
    private var needsPermission: Bool {
        guard let pm = permissionManager else { return false }
        return module.isAvailable && !pm.isGranted
    }

    /// Present onboarding via AppDelegate's standalone NSWindow (not .sheet).
    /// .sheet inside NSMenu causes NSWindow over-release crashes.
    private func presentOnboarding() {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        appDelegate.presentOnboardingWindow()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: module.icon)
                    .frame(width: 20)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text(module.name)
                        .font(.body.weight(.semibold))
                        .foregroundColor(module.isAvailable ? .primary : .secondary)
                    if !module.moduleDescription.isEmpty {
                        Text(module.moduleDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if !module.isAvailable {
                    // State 1: Unavailable -- "Coming Soon"
                    Text(String(localized: "status.coming_soon"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else if needsPermission {
                    // State 2: Available + Permission Blocked
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.orange)
                            Text(String(localized: "status.accessibility_required"))
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                        Button(String(localized: "status.open_settings")) {
                            presentOnboarding()
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundColor(.accentColor)
                    }
                } else {
                    // State 3: Available + has permission -- normal toggle
                    if usesPanelToggleStyle {
                        Toggle("", isOn: isEnabledBinding)
                            .toggleStyle(PanelSwitchToggleStyle())
                    } else {
                        Toggle("", isOn: isEnabledBinding)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                if needsPermission {
                    presentOnboarding()
                }
            }
        }
    }
}
