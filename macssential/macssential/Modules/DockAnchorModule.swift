import SwiftUI
import CoreGraphics
import ApplicationServices

@Observable
final class DockAnchorModule: FeatureModule, @unchecked Sendable {
    let id = "dock-anchor"
    var name: String { String(localized: "module.dock_anchor.name") }
    var moduleDescription: String { String(localized: "module.dock_anchor.description") }
    let icon = "dock.rectangle"
    let isAvailable = true
    let requiresAccessibilityPermission = true

    // Internal (not private) so tests can verify pause/resume state
    let interceptor = DockEventInterceptor()

    /// The user's preferred display as a persistent fingerprint.
    /// Survives disconnects/reconnects unlike CGDirectDisplayID (RESEARCH.md Pitfall 1).
    var preferredDisplay: DisplayIdentifier? {
        didSet {
            persistPreferredDisplay()
        }
    }

    /// Runtime display ID currently targeted by the interceptor.
    var activeDisplayID: CGDirectDisplayID

    /// Status message shown in panel (per D-02). Nil means no message (per D-05: silent restore).
    var statusMessage: String?

    /// User-configurable modifier key for temporary bypass (per D-06). Default: Option.
    var selectedModifierKey: ModifierKeyOption {
        didSet {
            UserDefaults.standard.set(selectedModifierKey.rawValue, forKey: ModifierKeyOption.defaultsKey)
            interceptor.activeModifierMask = selectedModifierKey.eventFlags
        }
    }

    /// Debouncing work item for screen change notifications (RESEARCH.md Pitfall 3).
    private var screenChangeWorkItem: DispatchWorkItem?

    /// Backward-compatible computed property for DisplayPickerView binding.
    /// Per D-07: persist selected monitor across app restarts.
    var selectedDisplayID: CGDirectDisplayID {
        get { activeDisplayID }
        set {
            activeDisplayID = newValue
            preferredDisplay = DisplayIdentifier.from(displayID: newValue)
            UserDefaults.standard.set(Int(newValue), forKey: "com.macssential.module.dock-anchor.monitor")
            if isEnabled && interceptor.isRunning {
                interceptor.targetDisplayID = newValue
            }
        }
    }

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "com.macssential.module.dock-anchor.enabled")
            if isEnabled { activate() } else { deactivate() }
        }
    }

    init() {
        // Load isEnabled
        self.isEnabled = UserDefaults.standard.bool(forKey: "com.macssential.module.dock-anchor.enabled")

        // Load modifier key preference (T-04-01: validate against known enum cases, fallback to .option)
        let storedModifier = UserDefaults.standard.string(forKey: ModifierKeyOption.defaultsKey)
        self.selectedModifierKey = storedModifier.flatMap { ModifierKeyOption(rawValue: $0) } ?? .option

        // Load preferred display from JSON (T-04-02: Codable decoding with try/catch, fallback to nil)
        var loadedPreferred: DisplayIdentifier? = nil
        if let data = UserDefaults.standard.data(forKey: "com.macssential.module.dock-anchor.preferred-display") {
            loadedPreferred = try? JSONDecoder().decode(DisplayIdentifier.self, from: data)
        }
        self.preferredDisplay = loadedPreferred

        // Resolve active display ID
        if let preferred = loadedPreferred, let liveID = preferred.findCurrentDisplayID() {
            self.activeDisplayID = liveID
        } else {
            let storedMonitor = UserDefaults.standard.integer(forKey: "com.macssential.module.dock-anchor.monitor")
            self.activeDisplayID = storedMonitor != 0 ? CGDirectDisplayID(storedMonitor) : CGMainDisplayID()
        }

        // Apply modifier mask to interceptor
        interceptor.activeModifierMask = selectedModifierKey.eventFlags

        // Register for screen change notifications (D-03)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenConfigurationDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        screenChangeWorkItem?.cancel()
    }

    func activate() {
        guard isAvailable else { return }
        // T-03-08: Check AXIsProcessTrusted() before starting event tap.
        guard AXIsProcessTrusted() else { return }
        interceptor.start(targetDisplayID: activeDisplayID)
    }

    func deactivate() {
        interceptor.stop()
    }

    /// Live-resource module: quit/permission-revoke must stop the CGEventTap
    /// so the Dock isn't stuck anchored after the app exits.
    func releaseResources() {
        deactivate()
    }

    @MainActor var settingsView: AnyView? {
        guard isEnabled else { return nil }
        let isAutoPaused = NSScreen.screens.count <= 1 && isEnabled
        return AnyView(
            VStack(spacing: 0) {
                DisplayPickerView(
                    selectedDisplayID: Binding(
                        get: { self.selectedDisplayID },
                        set: { self.selectedDisplayID = $0 }
                    ),
                    isEnabled: true,
                    statusMessage: statusMessage,
                    onStatusDismiss: { self.statusMessage = nil },
                    isAutoPaused: isAutoPaused
                )

                // Modifier key selector (per UI-SPEC Component 2).
                // Segmented, not .menu: a .menu Picker's popup cannot open while
                // the parent NSMenu's tracking loop owns events (same root cause
                // as the FinderSort fix in d70466d).
                HStack {
                    Text(String(localized: "label.temporary_unlock"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { self.selectedModifierKey },
                        set: { self.selectedModifierKey = $0 }
                    )) {
                        ForEach(ModifierKeyOption.allCases, id: \.self) { option in
                            Text(option.symbol).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 8)
            }
        )
    }

    // MARK: - Screen Change Handling

    /// Debounced handler for screen configuration changes (RESEARCH.md Pitfall 3).
    /// macOS fires didChangeScreenParametersNotification 2-4 times per physical disconnect.
    @objc private func screenConfigurationDidChange(_ notification: Notification) {
        screenChangeWorkItem?.cancel()
        screenChangeWorkItem = DispatchWorkItem { [weak self] in
            self?.handleScreenChange()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: screenChangeWorkItem!)
    }

    /// Processes screen configuration change after debounce.
    /// Internal visibility for testability.
    func handleScreenChange() {
        let screens = NSScreen.screens

        // D-09: Single monitor = auto-pause interceptor. Toggle stays ON.
        if screens.count <= 1 {
            if interceptor.isRunning && !interceptor.isPaused {
                interceptor.pause()
            }
            statusMessage = "Paused \u{2014} single monitor detected"
            return
        }

        // Check if preferred display is reconnected
        if let preferred = preferredDisplay,
           let liveID = preferred.findCurrentDisplayID() {
            // D-05: Silent restore to preferred monitor
            activeDisplayID = liveID
            if interceptor.isPaused {
                interceptor.resume()
            }
            interceptor.targetDisplayID = liveID
            if isEnabled && !interceptor.isRunning {
                activate()
            }
            statusMessage = nil
        } else {
            // Preferred monitor gone -- fallback to main display
            let fallbackID = CGMainDisplayID()

            // Get fallback monitor name
            let fallbackName = NSScreen.screens.first(where: {
                $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == fallbackID
            })?.localizedName ?? "Unknown"

            activeDisplayID = fallbackID
            if interceptor.isPaused {
                interceptor.resume()
            }
            interceptor.targetDisplayID = fallbackID
            if isEnabled && !interceptor.isRunning {
                activate()
            }
            // D-02: Status message for panel
            statusMessage = "Monitor disconnected \u{2014} switched to \(fallbackName)"
        }
    }

    // MARK: - Persistence Helpers

    private func persistPreferredDisplay() {
        if let preferred = preferredDisplay,
           let data = try? JSONEncoder().encode(preferred) {
            UserDefaults.standard.set(data, forKey: "com.macssential.module.dock-anchor.preferred-display")
        } else {
            UserDefaults.standard.removeObject(forKey: "com.macssential.module.dock-anchor.preferred-display")
        }
    }

    /// Computed accessor for interceptor pause state (for UI/tests).
    var isInterceptorPaused: Bool {
        interceptor.isPaused
    }
}
