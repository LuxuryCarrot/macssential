import CoreGraphics
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

    init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: "com.macssential.module.scroll-direction.enabled")
    }

    func activate() {
        startEventTap()
    }

    func deactivate() {
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

        guard let eventTap else { return } // nil = no Accessibility permission (T-09-03)

        runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func stopEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
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
