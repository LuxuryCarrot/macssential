import AppKit
import ApplicationServices

/// Calls AXIsProcessTrustedWithOptions with the prompt flag.
/// Free function to avoid Swift 6 concurrency errors with kAXTrustedCheckOptionPrompt
/// inside a @MainActor class.
private nonisolated func _promptSystemPermissionUnsafe() {
    // Use string literal "AXTrustedCheckOptionPrompt" instead of kAXTrustedCheckOptionPrompt
    // to avoid Swift 6 concurrency error (shared mutable state).
    // The value of kAXTrustedCheckOptionPrompt is this exact string.
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    AXIsProcessTrustedWithOptions(options)
}

@Observable
@MainActor
final class AccessibilityPermissionManager {
    var isGranted: Bool = AXIsProcessTrusted()
    private var pollTimer: Timer?

    /// Called when permission transitions from granted → revoked.
    var onPermissionRevoked: (() -> Void)?

    /// Called when permission transitions from revoked → granted.
    /// Use this to reactivate modules after the user grants permission while the app is running.
    var onPermissionRestored: (() -> Void)?

    private static let wasGrantedKey = "com.macssential.app.accessibilityWasGranted"

    /// True if the user previously granted permission but it was lost
    /// (e.g., after app update, Xcode rebuild, or binary path change).
    var needsReauthorization: Bool {
        !isGranted && UserDefaults.standard.bool(forKey: Self.wasGrantedKey)
    }

    /// Whether the manager is currently polling for permission changes.
    var isPolling: Bool {
        pollTimer != nil
    }

    /// Injectable trust check for tests. Defaults to the real AX API.
    var trustCheck: () -> Bool = { AXIsProcessTrusted() }

    /// Check current Accessibility permission status.
    /// Updates `isGranted` and persists grant state for re-auth detection.
    ///
    /// Fires the same transition callbacks as the poll loop. Previously this
    /// method overwrote `isGranted` WITHOUT firing them — if a revoked→granted
    /// transition was first observed here (e.g., panel open) instead of by the
    /// poll, `onPermissionRestored` never fired, `activateEnabledModules()` never
    /// ran, and every tap module stayed enabled-but-dead with permission granted.
    @discardableResult
    func checkPermission() -> Bool {
        applyPermissionState(trustCheck())
        return isGranted
    }

    /// Central transition handler — ALL `isGranted` updates flow through here so
    /// grant/revoke transitions fire their callbacks exactly once regardless of
    /// whether the poll or an ad-hoc checkPermission() observes the change first.
    private func applyPermissionState(_ granted: Bool) {
        let wasGranted = isGranted
        isGranted = granted
        if granted {
            UserDefaults.standard.set(true, forKey: Self.wasGrantedKey)
            if !wasGranted {
                // Transition: revoked → granted. Reactivate modules.
                onPermissionRestored?()
            }
        } else if wasGranted {
            // Transition: granted → revoked. Tear down event taps.
            onPermissionRevoked?()
        }
    }

    /// Prompt the system Accessibility permission dialog for the CURRENT binary.
    /// This ensures the running process (e.g., Xcode debug build from DerivedData)
    /// gets registered, not a stale entry from a previous build path.
    func promptSystemPermission() {
        _promptSystemPermissionUnsafe()
        checkPermission()
    }

    /// Open System Settings to the Accessibility privacy pane.
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Start polling for permission changes at the given interval.
    /// Automatically stops any existing polling first.
    /// When `onPermissionRevoked` is set, fires it on the first true → false transition.
    func startPolling(interval: TimeInterval = 1.0) {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyPermissionState(self.trustCheck())
            }
        }
    }

    /// Stop polling for permission changes.
    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
