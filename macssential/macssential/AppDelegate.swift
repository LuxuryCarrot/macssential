import AppKit
import Sparkle
import SwiftUI

@main
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    private let registry = ModuleRegistry()
    private let permissionManager = AccessibilityPermissionManager()
    private let localizationService = LocalizationService()
    private lazy var panelConfiguration = PanelConfiguration(
        allModuleIDs: registry.modules.map(\.id),
        language: localizationService.currentLanguage,
        systemAffectedByNFD: NFDFilenameIssue.affectsSystemLanguages()
    )
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private lazy var updaterService = UpdaterService(updater: updaterController.updater)
    private var statusItem: NSStatusItem!
    private var mainMenu: NSMenu!
    private var languageMenuItem: NSMenuItem!
    private var panelMenuItem: NSMenuItem!
    private var hostingView: NSView!
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Release live runtime resources only (stops CGEventTaps/FSEvents streams)
        // so the Dock isn't stuck anchored after quit. Preference modules
        // (autohide, show-recents, key repeat, hidden files) stay as configured —
        // quit must never revert user-visible system preferences.
        // Must happen here, not in applicationShouldTerminate — that returns .terminateNow
        // which can kill the process before cleanup finishes.
        registry.releaseAllRuntimeResources()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // First-launch relocation to /Applications (LetsMove-style). If it moves the
        // app and relaunches, stop here — this copy is about to terminate.
        if AppRelocationService.relocateToApplicationsIfNeeded() { return }

        // Check Accessibility permission and handle first-time vs re-authorization.
        if !permissionManager.checkPermission() {
            // Register CURRENT binary with the system
            permissionManager.promptSystemPermission()
            if permissionManager.needsReauthorization {
                // Returning user after update/rebuild — open Settings directly
                permissionManager.openSystemSettings()
            }
        }
        setupStatusItem()
        setupMainMenu()
        registry.activateEnabledModules()

        // Start lifetime background polling so permission revocation is detected
        // even after the onboarding view is dismissed.
        // When permission transitions granted → revoked, immediately deactivate all
        // modules that hold CGEventTaps to prevent system-wide input freeze.
        permissionManager.onPermissionRevoked = { [weak self] in
            // Stop CGEventTaps to prevent system-wide input freeze; do not
            // revert system preferences — revocation is not a user toggle-OFF.
            self?.registry.releaseAllRuntimeResources()
        }
        permissionManager.onPermissionRestored = { [weak self] in
            self?.registry.activateEnabledModules()
        }
        permissionManager.startPolling(interval: 1.0)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            if let image = NSImage(named: "MenuBarIcon") {
                image.isTemplate = true
                button.image = image
            } else {
                // Fallback: use SF Symbol or text if asset not found
                if let sfImage = NSImage(systemSymbolName: "m.square", accessibilityDescription: "macssential") {
                    sfImage.isTemplate = true
                    button.image = sfImage
                } else {
                    button.title = "M"
                }
            }
            button.action = #selector(handleClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func setupMainMenu() {
        mainMenu = NSMenu()

        // Language picker: 🌐 + current language name, submenu with EN/KO/JA
        languageMenuItem = NSMenuItem()
        languageMenuItem.title = languageMenuTitle()
        let langSubmenu = NSMenu()
        for (idx, lang) in AppLanguage.allCases.enumerated() {
            let item = NSMenuItem(
                title: lang.displayName,
                action: #selector(selectLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = idx
            langSubmenu.addItem(item)
        }
        languageMenuItem.submenu = langSubmenu
        mainMenu.addItem(languageMenuItem)

        panelMenuItem = NSMenuItem()
        hostingView = NSHostingView(rootView: makeMainPanelView())
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(x: 0, y: 0, width: fittingSize.width, height: fittingSize.height)
        panelMenuItem.view = hostingView
        mainMenu.addItem(panelMenuItem)
    }

    /// Builds the main panel SwiftUI view with environment injected.
    /// Extracted so the panel can be rebuilt fresh on each open, forcing SwiftUI
    /// to re-evaluate its body against the just-checked permission state.
    private func makeMainPanelView() -> some View {
        MainPanelView()
            .environment(registry)
            .environment(permissionManager)
            .environment(localizationService)
            .environment(panelConfiguration)
    }

    private func languageMenuTitle() -> String {
        "🌐 \(localizationService.currentLanguage.displayName)"
    }

    @objc private func selectLanguage(_ item: NSMenuItem) {
        let langs = AppLanguage.allCases
        guard langs.indices.contains(item.tag) else { return }
        localizationService.setLanguage(langs[item.tag])
        languageMenuItem.title = languageMenuTitle()
    }

    @objc private func handleClick(_ sender: NSButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            showMainPanel()
        }
    }

    private func showMainPanel() {
        // Re-check accessibility permission before showing panel.
        // onAppear doesn't fire reliably inside NSMenu-hosted SwiftUI views.
        permissionManager.checkPermission()
        // Rebuild the hosting view fresh against the just-checked permission state.
        // checkPermission()'s @Observable mutation only *schedules* a SwiftUI update;
        // the synchronous performClick() below would otherwise display the stale
        // initial render (e.g. "permission required" even after it was granted).
        // A brand-new NSHostingView reads current observable values at layout time,
        // and its fittingSize also reflects expanded/collapsed module settingsViews.
        let refreshed = NSHostingView(rootView: makeMainPanelView())
        refreshed.frame.size = refreshed.fittingSize
        hostingView = refreshed
        panelMenuItem.view = refreshed
        statusItem.menu = mainMenu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil // Clear so next click triggers action handler, not menu
    }

    private func showContextMenu() {
        let contextMenu = NSMenu()
        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        contextMenu.addItem(settingsItem)
        contextMenu.addItem(NSMenuItem.separator())
        contextMenu.addItem(
            NSMenuItem(
                title: "Quit macssential",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q")
        )
        statusItem.menu = contextMenu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil // Per RESEARCH.md Pitfall 2: must nil out to restore action handler
    }

    @objc private func openSettings() {
        showSettingsWindow()
    }

    func showSettingsWindow() {
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "macssential Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(updaterService: updaterService)
            .environment(registry)
            .environment(localizationService)
            .environment(panelConfiguration)
            .environment(permissionManager))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindow = window
    }

    /// Present the Accessibility onboarding as a standalone NSWindow.
    /// Fallback for when .sheet inside NSMenu doesn't work.
    func presentOnboardingWindow() {
        // Close any existing onboarding window first
        onboardingWindow?.close()
        onboardingWindow = nil

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.isReleasedWhenClosed = false
        self.onboardingWindow = window

        // Pass window reference so the view can close it directly
        let onboardingView = AccessibilityOnboardingView(
            permissionManager: permissionManager,
            hostWindow: window
        )
        window.contentView = NSHostingView(rootView: onboardingView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
