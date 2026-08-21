import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Supplies window snapshots for the switcher overlay's tiles.
///
/// Three properties define this service, and each is a deliberate constraint
/// rather than an implementation detail:
///
/// 1. **It never provokes the Screen Recording prompt.** Every gate uses
///    `CGPreflightScreenCaptureAccess()`, which reports the current TCC answer
///    without asking. `CGRequestScreenCaptureAccess()` appears exactly once, in
///    `requestPermission()`, which is reachable only from an explicit button in the
///    module's settings row. Launching the app, enabling the module, using the
///    switcher, and pre-warming all leave TCC untouched.
/// 2. **It is entirely optional.** Without permission `requestThumbnails` returns
///    immediately and the overlay renders large app icons. Switching works
///    identically; only the preview imagery is missing.
/// 3. **Captured pixels never leave memory and never outlive the module.** Images
///    live in a bounded in-memory dictionary. Nothing is written to disk, logged, or
///    transmitted (T-HGV-01 / T-I8L-01), and window titles are never logged
///    (inherited T-F4Y-03 disposition). `purge()` empties the cache on module
///    deactivate, `releaseResources()`, and permission revocation; every session
///    start additionally evicts entries for windows that no longer exist.
///
/// **Why the cache exists (latency).** The public capture contract is
/// enumerate-then-capture, and enumeration is an IPC round trip to the window server
/// that costs far more than the captures themselves. Paying it — plus a full capture
/// pass — on every Cmd+Tab is what made tiles visibly fill in. So: shared content is
/// cached for `contentTTL`, captures run concurrently, and the last known image for a
/// window is replayed into its tile immediately while a fresh capture overwrites it
/// in the background (stale-while-revalidate). Apple's own switcher reads
/// already-composited surfaces through private in-process WindowServer infrastructure
/// and never crosses TCC; third-party apps have no equivalent, so the goal here is
/// "already there on the second press", not parity on the first.
///
/// **Memory ceiling.** `cacheCapacity` entries at `downscaleFactor` scale: a
/// 1600x1000pt window lands near 400x250px x 4 bytes ~= 400 KB, so roughly 16 MB
/// worst case, and in practice far less because each session prunes the cache down to
/// the windows that currently exist.
///
/// `@MainActor` matches the app's service style and makes the cache free of locking:
/// captures run on the concurrent executor and only their delivery hops back.
@MainActor
final class WindowThumbnailService {

    /// Snapshot longest-edge budget. Tiles render at 160x92pt, so a quarter of a
    /// typical window's point size is already generous — capturing at full window
    /// resolution would cost far more time and memory for pixels nobody sees.
    private static let downscaleFactor: CGFloat = 0.25

    /// How long an enumerated `SCShareableContent` may be reused.
    ///
    /// Short enough that a window opened moments ago still appears (a miss only
    /// costs that tile its thumbnail for one session), long enough that the
    /// double-tap Cmd+Tab pattern pays the enumeration once instead of twice.
    private static let contentTTL: TimeInterval = 2.0

    /// Hard ceiling on retained images. See the memory note above.
    private static let cacheCapacity = 40

    /// Minimum spacing between pre-warm refreshes.
    private static let prewarmInterval: TimeInterval = 10

    /// Windows captured during the current session, keyed by `SwitcherWindow.id`.
    /// Doubles as the "already captured" ledger enforcing one capture pass per
    /// window per session; it is NOT the image cache and is cleared on every session
    /// boundary.
    private var captured: Set<String> = []

    /// In-flight capture work, cancelled wholesale by `endSession()`.
    private var task: Task<Void, Never>?

    /// Bumped for every capture pass so a finishing pass can tell whether `task`
    /// still refers to it. Without this, a cancelled pass completing after the next
    /// session started would clear the *new* session's task handle and leave that
    /// work uncancellable.
    private var captureGeneration = 0

    /// True while a switcher session is live. Results landing after Cmd release are
    /// dropped rather than applied to a dismissed overlay.
    private var sessionActive = false

    /// Last enumeration of shareable windows, with the time it was taken.
    private var contentCache: (content: SCShareableContent, at: Date)?

    /// The single in-flight enumeration. Overlapping callers await this one rather
    /// than each starting their own round trip to the window server.
    ///
    /// The result is boxed because a `Task`'s success type must be `Sendable` to be
    /// awaited from another isolation domain, and ScreenCaptureKit's types are not.
    private var contentFetch: Task<ShareableContentBox?, Never>?

    /// Carries an enumeration result out of its fetch task.
    ///
    /// `@unchecked Sendable`: `SCShareableContent` is a read-only snapshot of the
    /// window server's state at one instant. It is produced once, never mutated, and
    /// only ever read (`windows`, and each window's id/frame/title/owner) — first on
    /// the main actor, then from capture children that copy out what they need.
    private struct ShareableContentBox: @unchecked Sendable {
        let content: SCShareableContent
    }

    /// Last pre-warm, for throttling.
    private var lastPrewarm: Date?

    /// Last known image per `SwitcherWindow.id`, surviving across sessions.
    private var cache: [String: NSImage] = [:]

    /// Cache keys in most-recently-used-first order.
    private var lruOrder: [String] = []

    /// A window handed to a concurrent capture child.
    ///
    /// `@unchecked Sendable`: `SCWindow` is an immutable descriptor of a window that
    /// already exists in the window server, and the only thing done with it off the
    /// main actor is reading `frame` and building an `SCContentFilter`. Nothing here
    /// mutates it, and no second reference is written through.
    private struct CaptureRequest: @unchecked Sendable {
        let id: String
        let window: SCWindow
    }

    /// A finished snapshot on its way back to the main actor.
    ///
    /// `@unchecked Sendable`: the `NSImage` is constructed inside the capture, is
    /// never touched again by the producing task, and is handed over wholesale —
    /// a transfer of ownership, not shared mutable state.
    private struct CaptureResult: @unchecked Sendable {
        let id: String
        let image: NSImage
    }

    /// The current TCC answer for Screen Recording, asked without prompting.
    ///
    /// Safe to read at any time, including during app launch and SwiftUI body
    /// evaluation — this is precisely the call that lets the settings row show a
    /// permission hint without the hint itself triggering the prompt.
    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// The ONLY place the app may provoke the Screen Recording TCC prompt.
    ///
    /// Called from the explicit button in the Window Switcher settings row, never
    /// automatically. macOS shows the consent alert at most once per app; System
    /// Settings is opened alongside so a user who has already answered (or who
    /// dismisses the alert) still has somewhere to go.
    func requestPermission() {
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens a capture session and starts warming the window list immediately, so the
    /// enumeration overlaps the Accessibility work the module is doing in parallel
    /// instead of following it.
    func beginSession() {
        task?.cancel()
        task = nil
        captured.removeAll()
        sessionActive = true
        Task { [weak self] in _ = await self?.shareableContent() }
    }

    /// Closes the session and cancels in-flight capture.
    ///
    /// Deliberately does NOT drop cached images: replaying them is what makes the
    /// next Cmd+Tab appear populated instead of blank. Bounding and privacy are
    /// handled by the per-session prune in `requestThumbnails` and by `purge()`.
    func endSession() {
        sessionActive = false
        task?.cancel()
        task = nil
        captured.removeAll()
    }

    /// Drops every captured pixel and every cached window descriptor.
    ///
    /// The privacy backstop for the cross-session cache (T-I8L-01): reached from the
    /// module's `deactivate()` / `releaseResources()` path, so disabling the module,
    /// revoking Accessibility, and quitting all leave nothing behind.
    func purge() {
        endSession()
        cache.removeAll()
        lruOrder.removeAll()
        contentCache = nil
        contentFetch?.cancel()
        contentFetch = nil
        lastPrewarm = nil
    }

    /// Refreshes ONLY the window list, never pixels.
    ///
    /// Called on app-activation notifications — an event the user caused — and
    /// throttled to at most once per `prewarmInterval`, so there is no timer and no
    /// polling while the machine is idle. Costs one enumeration and keeps the next
    /// Cmd+Tab off the critical path entirely.
    func prewarm() {
        guard hasPermission else { return }
        if let lastPrewarm,
           WindowSwitcherEngine.ThumbnailCacheRules.isFresh(
               age: Date().timeIntervalSince(lastPrewarm), ttl: Self.prewarmInterval) {
            return
        }
        lastPrewarm = Date()
        Task { [weak self] in _ = await self?.shareableContent() }
    }

    /// The cached window list, re-enumerating only when stale.
    ///
    /// `SCShareableContent.excludingDesktopWindows` materialises an `SCWindow` and an
    /// `SCRunningApplication` for every on-screen window; it is the single most
    /// expensive step in the thumbnail path, which is why it is cached and shared
    /// rather than paid per session.
    private func shareableContent() async -> SCShareableContent? {
        if let contentCache,
           WindowSwitcherEngine.ThumbnailCacheRules.isFresh(
               age: Date().timeIntervalSince(contentCache.at), ttl: Self.contentTTL) {
            return contentCache.content
        }
        if let contentFetch { return await contentFetch.value?.content }

        let fetch = Task<ShareableContentBox?, Never> {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true) else { return nil }
            return ShareableContentBox(content: content)
        }
        contentFetch = fetch
        let content = await fetch.value?.content
        contentFetch = nil
        if let content { contentCache = (content, Date()) }
        return content
    }

    /// Populates `windows`' tiles: last known images immediately, fresh captures as
    /// they land.
    ///
    /// Every failure is swallowed: permission revoked mid-session, a window closed
    /// between enumeration and capture, an app that refuses to render. A missing
    /// thumbnail is a cosmetic downgrade to an app icon, and capture must never be
    /// able to break switching.
    func requestThumbnails(
        for windows: [SwitcherWindow],
        onImage: @escaping @MainActor (String, NSImage) -> Void
    ) {
        // Evict pixels for windows that no longer exist BEFORE anything else, so a
        // closed window's contents never survive a session boundary, and bound what
        // is left.
        prune(liveIDs: Set(windows.map(\.id)))

        // The permission gate comes first and costs one preflight call, so the
        // icon-fallback path never touches the capture stack at all.
        let permitted = hasPermission

        // Replay synchronously: this method is already on the main actor, so the
        // tiles are populated on the same turn of the run loop that shows the
        // overlay rather than a frame or more later.
        if permitted {
            for window in windows {
                guard WindowSwitcherEngine.ThumbnailCacheRules.shouldServeCached(
                    hasPermission: permitted, hasEntry: cache[window.id] != nil),
                      let image = cache[window.id] else { continue }
                touch(window.id)
                onImage(window.id, image)
            }
        }

        let pending = windows.filter {
            WindowSwitcherEngine.shouldAttemptCapture(
                hasPermission: permitted,
                sessionActive: sessionActive,
                alreadyCaptured: captured.contains($0.id)
            )
        }
        guard !pending.isEmpty else { return }
        pending.forEach { captured.insert($0.id) }

        task?.cancel()
        captureGeneration &+= 1
        let generation = captureGeneration
        task = Task { [weak self] in
            guard let self, let content = await self.shareableContent() else { return }
            if Task.isCancelled { return }

            // Flatten SCWindow into the value type the pure matcher understands,
            // keeping the SCWindow alongside so the match can be captured directly.
            var byID: [UInt32: SCWindow] = [:]
            var candidates: [WindowSwitcherEngine.ThumbnailCandidate] = []
            for scWindow in content.windows {
                guard let pid = scWindow.owningApplication?.processID else { continue }
                byID[scWindow.windowID] = scWindow
                candidates.append(WindowSwitcherEngine.ThumbnailCandidate(
                    windowID: scWindow.windowID,
                    pid: pid,
                    title: scWindow.title ?? "",
                    frame: scWindow.frame
                ))
            }

            let requests: [CaptureRequest] = pending.compactMap { window in
                guard let match = WindowSwitcherEngine.bestThumbnailMatch(for: window, in: candidates),
                      let scWindow = byID[match.windowID] else { return nil }
                return CaptureRequest(id: window.id, window: scWindow)
            }
            guard !requests.isEmpty else { return }

            // Concurrent, not serial: per-capture cost is small but the last tile of
            // a ten-window list would otherwise wait behind all nine before it.
            await withTaskGroup(of: CaptureResult?.self) { group in
                for request in requests {
                    group.addTask {
                        if Task.isCancelled { return nil }
                        guard let image = await Self.capture(request.window) else { return nil }
                        if Task.isCancelled { return nil }
                        return CaptureResult(id: request.id, image: image)
                    }
                }
                // Delivered one at a time on the main actor as each finishes, so the
                // grid keeps filling in progressively rather than all at once.
                for await result in group {
                    guard let result else { continue }
                    self.store(result.image, for: result.id)
                    // Re-check on delivery: the session can end while a capture is
                    // in flight, and a dismissed overlay must not be repainted.
                    guard self.sessionActive else { continue }
                    onImage(result.id, result.image)
                }
            }
            if self.captureGeneration == generation { self.task = nil }
        }
    }

    // MARK: - Image Cache

    private func store(_ image: NSImage, for id: String) {
        cache[id] = image
        touch(id)
        if lruOrder.count > Self.cacheCapacity {
            prune(liveIDs: Set(lruOrder))
        }
    }

    /// Marks `id` most recently used.
    private func touch(_ id: String) {
        lruOrder.removeAll { $0 == id }
        lruOrder.insert(id, at: 0)
    }

    /// Applies the pure retention policy: dead windows out first, then LRU overflow.
    private func prune(liveIDs: Set<String>) {
        let keep = WindowSwitcherEngine.ThumbnailCacheRules.retainedIDs(
            order: lruOrder, liveIDs: liveIDs, capacity: Self.cacheCapacity)
        lruOrder = keep
        let keepSet = Set(keep)
        cache = cache.filter { keepSet.contains($0.key) }
    }

    /// One window snapshot, downscaled at capture time. Returns nil on any failure.
    private static func capture(_ scWindow: SCWindow) async -> NSImage? {
        let configuration = SCStreamConfiguration()
        // Floor at 1: a zero-sized configuration is rejected, and a window can
        // legitimately report a degenerate frame while it is being created.
        configuration.width = max(Int(scWindow.frame.width * downscaleFactor), 1)
        configuration.height = max(Int(scWindow.frame.height * downscaleFactor), 1)
        configuration.showsCursor = false
        // .nominal keeps the requested point-based size instead of scaling up to
        // the display's backing resolution, which is the whole point of downscaling.
        configuration.captureResolution = .nominal

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        guard let cgImage = try? await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration
        ) else { return nil }

        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }
}
