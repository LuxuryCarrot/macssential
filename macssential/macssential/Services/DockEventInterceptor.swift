import CoreGraphics
import AppKit
import ApplicationServices

/// Intercepts mouse events via CGEventTap to prevent Dock relocation to non-target displays.
///
/// Security: Event mask explicitly includes ONLY mouse events (mouseMoved + 3 drag types).
/// No keyboard events are ever monitored (T-03-04).
/// Callback only returns nil (block) or passthrough -- never synthesizes or modifies events (T-03-05).
/// Callback is lightweight: coordinate comparison only, no I/O, no allocations (T-03-06).
final class DockEventInterceptor: @unchecked Sendable {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    var targetDisplayID: CGDirectDisplayID = CGMainDisplayID()

    /// Modifier key mask for temporary bypass. When this flag is present in an event,
    /// the event passes through without blocking. Default: Option key (per D-06).
    var activeModifierMask: CGEventFlags = .maskAlternate

    /// Whether the event tap is paused (disabled but not torn down).
    /// Pause preserves the CFMachPort so resume is instant -- no Dock restart needed.
    private(set) var isPaused: Bool = false

    /// Configurable trigger zone height (pixels from bottom edge of screen).
    /// Per RESEARCH.md: Start with 5px, make configurable.
    static let triggerHeight: CGFloat = 5.0

    func start(targetDisplayID: CGDirectDisplayID) {
        stop() // Clean up any existing tap
        self.targetDisplayID = targetDisplayID

        // SECURITY (T-03-04): Only mouse events. No keyboard events in mask.
        let eventMask: CGEventMask = (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseDragged.rawValue)
            | (1 << CGEventType.otherMouseDragged.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap, // CRITICAL: .defaultTap to enable event blocking
            eventsOfInterest: eventMask,
            callback: Self.eventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap else { return } // nil = no Accessibility permission

        runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    func stop() {
        let wasRunning = eventTap != nil
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            if let runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil

        // Only restart Dock when the tap was actually running. The Dock needs a restart
        // to reset its internal mouse tracking state after we've been blocking events.
        // Skipping this when the tap was never running prevents a spurious Dock restart
        // on every app launch (start() calls stop() as cleanup before creating a new tap).
        if wasRunning { restartDock() }
        isPaused = false
    }

    /// Pauses event interception without tearing down the tap or restarting Dock.
    /// Use for temporary disablement (e.g., single-monitor mode per D-09).
    /// Call resume() to re-enable. See RESEARCH.md "DockEventInterceptor Pause vs Stop".
    func pause() {
        guard let eventTap, !isPaused else { return }
        CGEvent.tapEnable(tap: eventTap, enable: false)
        isPaused = true
    }

    /// Resumes a previously paused event tap.
    func resume() {
        guard let eventTap, isPaused else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        isPaused = false
    }

    private func restartDock() {
        if let dock = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.dock"
        ).first {
            dock.terminate()
            // launchd auto-relaunches the Dock within ~0.5s
        }
    }

    var isRunning: Bool { eventTap != nil }

    // MARK: - C callback (static, not closure -- CGEventTapCallBack requirement)

    private static let eventCallback: CGEventTapCallBack = {
        proxy, type, event, userInfo in

        // Handle tap-disabled events.
        // tapDisabledByTimeout: re-enable unconditionally (macOS disabled due to slow callback).
        // tapDisabledByUserInput: re-enable ONLY if Accessibility permission is still granted.
        //   Revocation sends tapDisabledByUserInput — re-enabling here would keep the blocking
        //   tap alive after permission loss, causing a system-wide input freeze.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let userInfo, AXIsProcessTrusted() {
                let interceptor = Unmanaged<DockEventInterceptor>
                    .fromOpaque(userInfo).takeUnretainedValue()
                if let tap = interceptor.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let interceptor = Unmanaged<DockEventInterceptor>
            .fromOpaque(userInfo).takeUnretainedValue()

        // SECURITY (T-03-05): Only block or passthrough. Never synthesize or modify events.
        if interceptor.shouldBlockEvent(event: event) {
            return nil // Swallow event -- prevent Dock relocation
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: - Trigger zone logic (testable, pure functions)

    func shouldBlockEvent(event: CGEvent) -> Bool {
        // D-06: If configured modifier key is held, allow all events through
        if event.flags.contains(activeModifierMask) {
            return false
        }
        let cgPoint = event.location // CG coordinates: top-left origin
        return shouldBlockAtPoint(cgPoint: cgPoint)
    }

    /// Testable helper for modifier key bypass.
    /// CGEvent cannot be easily constructed in tests, so this method accepts flags directly.
    func shouldBlockAtPointWithFlags(cgPoint: CGPoint, flags: CGEventFlags) -> Bool {
        if flags.contains(activeModifierMask) {
            return false
        }
        return shouldBlockAtPoint(cgPoint: cgPoint)
    }

    func shouldBlockAtPoint(cgPoint: CGPoint) -> Bool {
        // Convert CG point to NS coordinates for comparison with NSScreen frames
        let nsPoint = Self.cgPointToNSPoint(cgPoint)

        for screen in NSScreen.screens {
            guard let displayID = Self.displayID(for: screen) else { continue }
            if displayID == targetDisplayID { continue } // Allow events on target screen

            if Self.isInDockTriggerZone(
                mouseLocation: nsPoint,
                screenFrame: screen.frame,
                triggerHeight: Self.triggerHeight
            ) {
                return true // Block: mouse in trigger zone of non-target screen
            }
        }
        return false
    }

    // MARK: - Pure helper functions (static, testable without CGEventTap)

    /// Returns true if the mouse location (NS coordinates) is within the trigger zone
    /// at the bottom edge of the given screen frame.
    static func isInDockTriggerZone(
        mouseLocation: NSPoint,
        screenFrame: CGRect,
        triggerHeight: CGFloat = 5.0
    ) -> Bool {
        // Check horizontal bounds
        guard mouseLocation.x >= screenFrame.minX &&
              mouseLocation.x <= screenFrame.maxX else { return false }
        // Check bottom edge zone (NS coordinates: y increases upward, bottom = minY)
        return mouseLocation.y >= screenFrame.minY &&
               mouseLocation.y <= screenFrame.minY + triggerHeight
    }

    /// Converts a CGEvent point (top-left origin, y down) to NSPoint (bottom-left origin, y up).
    /// Pitfall 3 from RESEARCH.md: coordinate system conversion is critical for correct trigger zones.
    static func cgPointToNSPoint(_ cgPoint: CGPoint) -> NSPoint {
        guard let primaryScreen = NSScreen.screens.first else {
            return NSPoint(x: cgPoint.x, y: cgPoint.y)
        }
        return NSPoint(
            x: cgPoint.x,
            y: primaryScreen.frame.height - cgPoint.y
        )
    }

    /// Extracts CGDirectDisplayID from an NSScreen's device description.
    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? CGDirectDisplayID
    }
}
