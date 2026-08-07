import AppKit

/// LetsMove-style first-launch relocation to /Applications, native Swift only.
///
/// A DMG drag-install has no hook to run a script, so the app moves itself on
/// first launch. Running from the DMG, Downloads, or an App Translocation path
/// scatters copies and pins the ad-hoc-signed Accessibility (TCC) grant to a
/// throwaway path/cdhash. Relocating to /Applications once gives a stable home.
///
/// The active logic lives inside `#if !DEBUG` so it never nags during local
/// development (Xcode/DerivedData runs). To exercise the real path you must
/// build a Release configuration.
@MainActor
enum AppRelocationService {
    /// Set once the user declines relocation from a normal (non-translocated)
    /// location, so we don't keep asking on every launch.
    private static let suppressKey = "com.macssential.app.suppressRelocationPrompt"

    private static let applicationsDir = "/Applications"

    /// Attempt to relocate the running app into /Applications when appropriate.
    ///
    /// - Returns: `true` if relocation + relaunch was started — the caller must
    ///   stop immediately because the current process is about to terminate.
    ///   `false` means "carry on as normal" (already installed, declined,
    ///   DEBUG build, or relocation failed and the user was told to drag it).
    @discardableResult
    static func relocateToApplicationsIfNeeded() -> Bool {
        let bundleURL = Bundle.main.bundleURL

        // 1. Already living in /Applications or ~/Applications — nothing to do.
        if isInApplicationsFolder(bundleURL) {
            return false
        }

        #if DEBUG
        // 2. Never relocate during development.
        return false
        #else
        // 3. Determine whether we're running from a translocated / read-only
        // location. Translocated apps always need relocating; if we're in a
        // plain writable spot and the user previously declined, respect that.
        let translocated = isTranslocated(bundleURL)
        if !translocated,
           UserDefaults.standard.bool(forKey: suppressKey) {
            return false
        }

        // 4. Ask the user.
        guard promptUserToMove() else {
            // Declined. From a normal location, remember the choice so we stop
            // asking. From a translocated copy, suppressing is pointless (the
            // path changes each launch), so don't persist anything.
            if !translocated {
                UserDefaults.standard.set(true, forKey: suppressKey)
            }
            return false
        }

        // 5. Install into /Applications (replacing any existing copy).
        let dest = URL(fileURLWithPath: applicationsDir)
            .appendingPathComponent("macssential.app")

        guard install(from: bundleURL, to: dest) else {
            presentManualInstallAlert()
            return false
        }

        // 6. Strip quarantine on the freshly installed copy (best-effort).
        removeQuarantine(at: dest)

        // 7. Relaunch the installed copy, then terminate this one.
        relaunch(at: dest)
        return true
        #endif
    }

    // MARK: - Location checks

    private static func isInApplicationsFolder(_ url: URL) -> Bool {
        let path = url.path
        let home = NSHomeDirectory()
        return path.hasPrefix("\(applicationsDir)/")
            || path.hasPrefix("\(home)/Applications/")
    }

    /// True if the app is running from an App Translocation path or a read-only
    /// volume (e.g. a mounted DMG). Either case means the current location is
    /// not a real, stable install.
    private static func isTranslocated(_ url: URL) -> Bool {
        if url.path.contains("/AppTranslocation/") {
            return true
        }
        if let values = try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]),
           values.volumeIsReadOnly == true {
            return true
        }
        return false
    }

    // MARK: - User prompts

    private static func promptUserToMove() -> Bool {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "macssential을 응용 프로그램 폴더로 이동할까요?"
        alert.informativeText = """
        앱을 응용 프로그램 폴더로 옮기면 정상적으로 동작하고 권한 설정이 안정적으로 유지됩니다.
        지금 이동하는 것을 권장합니다.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "응용 프로그램으로 이동")
        alert.addButton(withTitle: "이동 안 함")

        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func presentManualInstallAlert() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "자동 이동에 실패했습니다"
        alert.informativeText = """
        macssential을 직접 응용 프로그램 폴더로 끌어다 놓아 설치해 주세요.
        그런 다음 응용 프로그램 폴더에서 앱을 실행하세요.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }

    // MARK: - Install

    private static func install(from source: URL, to dest: URL) -> Bool {
        let fileManager = FileManager.default

        // Terminate any OTHER running instance with the same bundle id (e.g. an
        // older copy already in /Applications) so we can replace it cleanly.
        terminateOtherInstances()

        do {
            // Remove an existing copy at the destination, if present.
            if fileManager.fileExists(atPath: dest.path) {
                try fileManager.removeItem(at: dest)
            }
            // Copy (not move): the source may be on a read-only DMG. Leaving the
            // original behind in Downloads/DMG is acceptable.
            try fileManager.copyItem(at: source, to: dest)
            return true
        } catch {
            NSLog("[AppRelocationService] install failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Terminate other running instances sharing our bundle identifier, skipping
    /// the current process. Best-effort; failures are ignored.
    private static func terminateOtherInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let current = NSRunningApplication.current
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != current }

        guard !others.isEmpty else { return }
        for app in others {
            app.terminate()
        }
        // Give the other instances a brief moment to exit before we overwrite.
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Best-effort quarantine removal so the relaunched copy isn't gatekept.
    private static func removeQuarantine(at url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", url.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Ignore — quarantine removal is non-essential.
        }
    }

    // MARK: - Relaunch

    private static func relaunch(at url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                NSLog("[AppRelocationService] relaunch failed: \(error.localizedDescription)")
            }
            // Hop back to the main actor before touching NSApp.
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
    }
}
