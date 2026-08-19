import CoreGraphics
import AppKit
import SwiftUI
import ApplicationServices

/// Separates scroll direction for mouse (discrete) vs trackpad (continuous) events.
///
/// Uses a CGEventTap to intercept scrollWheel events. For discrete (mouse) events,
/// negates all three delta fields to reverse scroll direction. Continuous (trackpad)
/// events pass through unmodified.
///
/// Security:
/// - Event mask restricted to scrollWheel only (T-09-01)
/// - Callback is lightweight: integer field reads/writes only, no I/O, no allocations (T-09-02)
/// - tapDisabledByTimeout handled by re-enabling tap
/// - tapDisabledByUserInput re-enables only when AXIsProcessTrusted() is true, preventing
///   input freeze on Accessibility permission revocation
@Observable
final class ScrollDirectionModule: FeatureModule {
    let id = "scroll-direction"
    var name: String { String(localized: "module.scroll_direction.name") }
    var moduleDescription: String { String(localized: "module.scroll_direction.description") }
    let icon = "computermouse"
    let isAvailable = true
    let requiresAccessibilityPermission = true

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "com.macssential.module.scroll-direction.enabled")
            if isEnabled { activate() } else { deactivate() }
        }
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapWatchdogTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: "com.macssential.module.scroll-direction.enabled")
    }

    func activate() {
        startEventTap()
        startTapWatchdog()
    }

    func deactivate() {
        stopTapWatchdog()
        stopEventTap()
    }

    /// Live-resource module: quit/permission-revoke must stop the CGEventTap.
    func releaseResources() {
        deactivate()
    }

    // No settingsView override — inherits default nil from protocol extension (D-02: simple toggle only)

    // MARK: - CGEventTap Lifecycle

    private func startEventTap() {
        stopEventTap() // Clean up any existing tap

        // SECURITY (T-09-01): Only scrollWheel events. No other event types in mask.
        let eventMask: CGEventMask = (1 << CGEventType.scrollWheel.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.scrollCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap else {
            // nil = no Accessibility permission (T-09-03) or WindowServer refusal.
            // Log instead of failing silently — the toggle stays visually ON.
            NSLog("[macssential] ScrollDirectionModule: CGEvent.tapCreate returned nil — scroll interception unavailable")
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func stopEventTap() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            // Without an explicit invalidate, WindowServer keeps the tap registered
            // as a disabled zombie after the CFMachPort reference is released.
            CFMachPortInvalidate(eventTap)
        }
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: - Tap Health Watchdog

    /// macOS can silently disable a session CGEventTap over long uptime — sleep/wake
    /// cycles, secure-input sessions (lock-screen password fields), or WindowServer
    /// stress. The tapDisabledBy* recovery inside the callback only fires when that
    /// notification is actually delivered to a live tap; when the tap dies without it,
    /// scroll reversal stays broken until the tap is recreated (previously: only via a
    /// manual module toggle). This watchdog re-checks tap health periodically and on
    /// wake, re-enabling or recreating the tap as needed.
    private func startTapWatchdog() {
        stopTapWatchdog()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.ensureTapHealthy()
        }
        tapWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.ensureTapHealthy()
        }
    }

    private func stopTapWatchdog() {
        tapWatchdogTimer?.invalidate()
        tapWatchdogTimer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    /// Re-enables a disabled tap, or fully recreates it when the mach port is
    /// invalid or re-enabling is refused. Cheap when healthy (one state query).
    /// Skips work when permission is missing — the app-level permission poll
    /// handles revocation (releases taps) and restoration (reactivates modules).
    private func ensureTapHealthy() {
        guard isEnabled, AXIsProcessTrusted() else { return }
        guard let eventTap else {
            // Tap was never created (e.g., permission granted after activate) — create now.
            startEventTap()
            return
        }
        if !CFMachPortIsValid(eventTap) {
            // Port invalidated by the system — re-enable is impossible, recreate.
            startEventTap()
            return
        }
        if !CGEvent.tapIsEnabled(tap: eventTap) {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            if !CGEvent.tapIsEnabled(tap: eventTap) {
                // Re-enable refused — tap is unrecoverable in place, recreate.
                startEventTap()
            }
        }
    }

    // MARK: - Static Callback

    /// CGEventTapCallBack — must be static (C function pointer requirement).
    /// SECURITY (T-09-02): Lightweight — only integer field reads/writes, no I/O, no allocations, no blocking.
    private static let scrollCallback: CGEventTapCallBack = {
        proxy, type, event, userInfo in

        // Handle tap-disabled events.
        // tapDisabledByTimeout: re-enable unconditionally (macOS disabled due to slow callback).
        // tapDisabledByUserInput: re-enable ONLY if Accessibility permission is still granted.
        //   Revocation sends tapDisabledByUserInput — re-enabling here would keep the blocking
        //   tap alive after permission loss, causing system-wide input freeze.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let userInfo, AXIsProcessTrusted() {
                let module = Unmanaged<ScrollDirectionModule>
                    .fromOpaque(userInfo).takeUnretainedValue()
                if let tap = module.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        // Check if this is a discrete (mouse) or continuous (trackpad) scroll event
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous)

        if isContinuous == 0 {
            // Discrete mouse event — negate delta fields to reverse direction

            // Vertical axis
            let delta1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -delta1)

            let pointDelta1 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -pointDelta1)

            let fixedPtDelta1 = event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1)
            event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixedPtDelta1)

            // Horizontal axis
            let delta2 = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -delta2)

            let pointDelta2 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -pointDelta2)

            let fixedPtDelta2 = event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2)
            event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -fixedPtDelta2)
        }
        // Continuous (trackpad) events pass through unmodified

        return Unmanaged.passUnretained(event)
    }
}
