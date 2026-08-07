import SwiftUI

// MARK: - Arrange-By Options

/// Finder's `arrangeBy` values as stored in `IconViewSettings`.
/// Raw values match Finder's own strings exactly — they are written verbatim
/// into com.apple.finder, so only these enum cases can ever reach the plist
/// (no user-controlled strings, T-kvj-01).
enum FinderArrangeBy: String, CaseIterable {
    case name
    case kind
    case dateModified
    case dateCreated
    case dateAdded
    case size
    case label
    case grid

    var localizedTitle: String {
        switch self {
        case .name: return String(localized: "module.finder_sort.option.name")
        case .kind: return String(localized: "module.finder_sort.option.kind")
        case .dateModified: return String(localized: "module.finder_sort.option.date_modified")
        case .dateCreated: return String(localized: "module.finder_sort.option.date_created")
        case .dateAdded: return String(localized: "module.finder_sort.option.date_added")
        case .size: return String(localized: "module.finder_sort.option.size")
        case .label: return String(localized: "module.finder_sort.option.label")
        case .grid: return String(localized: "module.finder_sort.option.grid")
        }
    }
}

// MARK: - Finder Sort Applier

/// Abstracts writes to Finder's preference domain so tests can inject a spy
/// and never touch the user's real com.apple.finder plist or kill Finder.
protocol FinderSortApplying {
    /// Deep-mutates `arrangeBy` inside both `StandardViewSettings` and
    /// `FK_StandardViewSettings` IconViewSettings dicts.
    func apply(arrangeBy: String)
    /// Restores `arrangeBy = "none"` (the macOS factory default) in both dicts.
    func restoreDefault()
    /// Restarts Finder so the new default view settings take effect.
    func restartFinder()
}

/// Writes `arrangeBy` into com.apple.finder's default icon-view settings via
/// CFPreferences — the API equivalent of `defaults write com.apple.finder`.
/// No shelling out for pref writes, so no PATH/argument injection surface
/// (T-czd-03 pattern).
///
/// Only the `arrangeBy` key inside a copied dict is mutated; all sibling keys
/// (gridSpacing, icon size, colors, ...) are preserved verbatim on write-back
/// (T-kvj-04). The desktop's own view-settings dict is NEVER touched — the
/// user's desktop icon arrangement stays exactly as-is.
struct CFFinderSortApplier: FinderSortApplying, Sendable {

    private static let domain = "com.apple.finder"
    /// Both dicts feed Finder's default icon view: `StandardViewSettings` for
    /// regular windows, `FK_StandardViewSettings` for FileKit-backed views.
    private static let settingsKeys = ["StandardViewSettings", "FK_StandardViewSettings"]

    func apply(arrangeBy: String) {
        setArrangeBy(arrangeBy)
    }

    /// Honest restore: `arrangeBy = "none"` is the macOS factory default, so the
    /// system behaves as if never customized. The dicts themselves are kept —
    /// deleting them would also discard unrelated user view settings.
    func restoreDefault() {
        setArrangeBy("none")
    }

    /// Restarts Finder via `/usr/bin/killall` — fixed absolute path with constant
    /// arguments prevents PATH hijacking (Phase 08 pattern, T-kvj-02). Finder
    /// relaunches automatically; the restart is idempotent.
    func restartFinder() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Finder"]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("[macssential] FinderSort: failed to restart Finder — \(error)")
        }
    }

    // MARK: - Private

    private func setArrangeBy(_ value: String) {
        for key in Self.settingsKeys {
            let existing = CFPreferencesCopyValue(key as CFString,
                                                  Self.domain as CFString,
                                                  kCFPreferencesCurrentUser,
                                                  kCFPreferencesAnyHost)
            var outer = (existing as? [String: Any]) ?? [:]
            var iconViewSettings = (outer["IconViewSettings"] as? [String: Any]) ?? [:]
            iconViewSettings["arrangeBy"] = value
            outer["IconViewSettings"] = iconViewSettings
            CFPreferencesSetValue(key as CFString,
                                  outer as CFDictionary,
                                  Self.domain as CFString,
                                  kCFPreferencesCurrentUser,
                                  kCFPreferencesAnyHost)
        }
        CFPreferencesSynchronize(Self.domain as CFString,
                                 kCFPreferencesCurrentUser,
                                 kCFPreferencesAnyHost)
    }
}

// MARK: - Arrangement Enforcer

/// Abstracts the periodic "stamp every open Finder window" Apple Events call
/// so tests can inject a spy and never send real Apple Events to Finder.
protocol FinderArrangementEnforcing {
    func enforceArrangement(_ value: FinderArrangeBy)
}

/// Sends ONE batched Apple Events script to Finder that sets the icon-view
/// arrangement of ALL open Finder windows to the given value — writing into
/// each folder's own view settings, so even folders with a saved .DS_Store
/// stay auto-sorted.
///
/// Uses in-process NSAppleScript (no osascript Process — no shelling, no PATH
/// surface). Script text is built ONLY from the exhaustive switch below over
/// hardcoded constants; no user/defaults string ever reaches script text
/// (T-mpp-01, same injection posture as T-kvj-01).
///
/// Main-thread only: NSAppleScript is not thread-safe off the main thread.
/// The enforce timer fires on the main run loop, so all calls arrive on main.
/// `@unchecked Sendable` is justified by that main-thread-only contract
/// (ScreenshotAutoCopyModule precedent).
final class AppleScriptArrangementEnforcer: FinderArrangementEnforcing, @unchecked Sendable {

    /// Compiled-script cache: compile once per arrangeBy value, reuse across
    /// timer ticks; invalidated when the value changes (T-mpp-03).
    private var cachedValue: FinderArrangeBy?
    private var cachedScript: NSAppleScript?
    /// One-time logging flags so errors don't spam every 7s tick.
    private var loggedCompileFailure = false
    private var loggedExecuteFailure = false

    func enforceArrangement(_ value: FinderArrangeBy) {
        // Skip entirely when Finder is not running — sending an Apple Event
        // to a non-running app would launch it.
        let finderRunning = NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == "com.apple.finder" }
        guard finderRunning else { return }

        guard let script = compiledScript(for: value) else { return }

        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo, !loggedExecuteFailure {
            // e.g. -1743 Automation denied, Finder busy — tolerated silently
            // after the first log (T-mpp-02). Per-window -1728 (non-icon view)
            // never surfaces here: the script's per-window `try` swallows it.
            print("[macssential] FinderSort: enforce failed — \(errorInfo)")
            loggedExecuteFailure = true
        }
    }

    // MARK: - Private

    private func compiledScript(for value: FinderArrangeBy) -> NSAppleScript? {
        if cachedValue == value, let cachedScript { return cachedScript }

        let source = """
        tell application "Finder"
            repeat with w in every Finder window
                try
                    set arrangement of icon view options of w to \(Self.appleScriptConstant(for: value))
                end try
            end repeat
        end tell
        """
        let script = NSAppleScript(source: source)
        var errorInfo: NSDictionary?
        guard script?.compileAndReturnError(&errorInfo) == true else {
            // e.g. `arranged by date added` unsupported on some macOS versions —
            // treat the value as unsupported and skip enforcement silently.
            if !loggedCompileFailure {
                print("[macssential] FinderSort: enforce script compile failed for \(value.rawValue) — \(errorInfo ?? [:])")
                loggedCompileFailure = true
            }
            cachedValue = value
            cachedScript = nil
            return nil
        }
        cachedValue = value
        cachedScript = script
        return script
    }

    /// Exhaustive switch over the enum ONLY — hardcoded AppleScript constants,
    /// never interpolated user/defaults strings (T-mpp-01).
    private static func appleScriptConstant(for value: FinderArrangeBy) -> String {
        switch value {
        case .name: return "arranged by name"
        case .kind: return "arranged by kind"
        case .dateModified: return "arranged by modification date"
        case .dateCreated: return "arranged by creation date"
        case .dateAdded: return "arranged by date added"
        case .size: return "arranged by size"
        case .label: return "arranged by label"
        case .grid: return "snap to grid"
        }
    }
}

// MARK: - FinderSortModule

/// Sets Finder's DEFAULT arrange-by order for folders that have no per-folder
/// view settings — new folders, unzipped folders, and never-visited folders
/// auto-sort so icons stop escaping the window on resize.
///
/// Limitation: folders that ALREADY carry their own .DS_Store view settings
/// keep their per-folder sort; this module only changes the DEFAULT for
/// new/unvisited folders (exactly the pain case). Aggressive .DS_Store
/// cleanup is out of scope.
///
/// Finder restarts exactly once per discrete user action (toggle or Picker
/// selection) so the change takes effect immediately (T-kvj-03).
@Observable
final class FinderSortModule: FeatureModule, @unchecked Sendable {
    // @unchecked Sendable: the enforce Timer's @Sendable block captures self;
    // all mutation happens on the main thread (UI + main-run-loop timer), same
    // justification as ScreenshotAutoCopyModule.
    let id = "finder-sort"
    var name: String { String(localized: "module.finder_sort.name") }
    var moduleDescription: String { String(localized: "module.finder_sort.description") }
    let icon = "square.grid.3x3.topleft.filled"
    let isAvailable = true

    private static let enabledKey = "com.macssential.module.finder-sort.enabled"
    private static let arrangeByKey = "com.macssential.module.finder-sort.arrangeBy"
    private static let enforceKey = "com.macssential.module.finder-sort.enforce"

    private let applier: FinderSortApplying
    private let enforcer: FinderArrangementEnforcing
    private let defaults: UserDefaults
    private var enforceTimer: Timer?

    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { activate() } else { deactivate() }
        }
    }

    /// The default arrange-by order to apply. A Picker selection is one discrete
    /// user action — it triggers exactly one apply + one Finder restart.
    /// No extra enforce call on change: the next timer tick picks up the new
    /// value (the enforcer's compiled-script cache keys on the value).
    var arrangeBy: FinderArrangeBy {
        didSet {
            defaults.set(arrangeBy.rawValue, forKey: Self.arrangeByKey)
            if isEnabled {
                applier.apply(arrangeBy: arrangeBy.rawValue)
                applier.restartFinder()
            }
        }
    }

    /// When on, a repeating timer stamps every open Finder window's icon-view
    /// arrangement — even folders with their own saved .DS_Store settings.
    var enforceSort: Bool {
        didSet {
            defaults.set(enforceSort, forKey: Self.enforceKey)
            if isEnabled && enforceSort {
                startEnforceTimer()
            } else {
                stopEnforceTimer()
            }
        }
    }

    init(applier: FinderSortApplying = CFFinderSortApplier(),
         enforcer: FinderArrangementEnforcing = AppleScriptArrangementEnforcer(),
         defaults: UserDefaults = .standard) {
        self.applier = applier
        self.enforcer = enforcer
        self.defaults = defaults
        // Direct stored-property assignment in init never fires didSet, so
        // loading persisted state causes no side effects (no apply, no timer).
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        // Unknown persisted rawValue falls back to .name on load.
        let storedRaw = defaults.string(forKey: Self.arrangeByKey) ?? FinderArrangeBy.name.rawValue
        self.arrangeBy = FinderArrangeBy(rawValue: storedRaw) ?? .name
        self.enforceSort = defaults.bool(forKey: Self.enforceKey)
    }

    @MainActor var settingsView: AnyView? {
        AnyView(FinderSortSettingsView(module: self))
    }

    func activate() {
        applier.apply(arrangeBy: arrangeBy.rawValue)
        applier.restartFinder()
        if enforceSort { startEnforceTimer() }
    }

    /// Turning the module off restores the macOS factory default
    /// (`arrangeBy = "none"`) in both dicts and restarts Finder once.
    func deactivate() {
        stopEnforceTimer()
        applier.restoreDefault()
        applier.restartFinder()
    }

    /// Live-resource pattern (fd0/DockAnchor): app quit and permission revoke
    /// stop the enforce timer without touching preference state.
    func releaseResources() {
        stopEnforceTimer()
    }

    // MARK: - Enforce Timer

    /// Idempotent: invalidates any existing timer before scheduling. Runs on
    /// the main run loop (Timer.scheduledTimer from the main thread), so the
    /// enforcer's NSAppleScript work always happens on the main thread.
    /// Fires one immediate enforcement pass so the user sees the effect
    /// without waiting for the first 7s interval.
    ///
    /// DEBUG-only: the enforce feature is experimental and must never run in
    /// Release builds — even if com.macssential.module.finder-sort.enforce is
    /// true from a previous Debug build. Gating the body here makes every call
    /// site (enforceSort didSet, activate()) a no-op in Release. The persisted
    /// key is intentionally NOT deleted so Debug builds keep the user's state.
    private func startEnforceTimer() {
        #if DEBUG
        stopEnforceTimer()
        enforcer.enforceArrangement(arrangeBy)
        enforceTimer = Timer.scheduledTimer(withTimeInterval: 7, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.enforcer.enforceArrangement(self.arrangeBy)
        }
        #endif
    }

    private func stopEnforceTimer() {
        enforceTimer?.invalidate()
        enforceTimer = nil
    }
}
