import SwiftUI
import ServiceManagement
import AppKit

struct SettingsView: View {
    let updaterService: UpdaterService
    @Environment(ModuleRegistry.self) private var registry
    @Environment(PanelConfiguration.self) private var panelConfig
    @Environment(AccessibilityPermissionManager.self) private var permissionManager
    @Environment(LocalizationService.self) private var localizationService
    @State private var launchAtLogin: Bool = false
    @State private var screenshotFormat: String = {
        UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "type") ?? "png"
    }()
    @State private var screenshotLocation: String = {
        UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
            ?? NSHomeDirectory() + "/Desktop"
    }()

    private var hiddenFilesModule: HiddenFilesModule? {
        registry.modules.first(where: { $0.id == "hidden-files" }) as? HiddenFilesModule
    }

    private var screenshotModule: ScreenshotAutoCopyModule? {
        registry.modules.first(where: { $0.id == "screenshot-auto-copy" }) as? ScreenshotAutoCopyModule
    }

    private var kfnModule: KoreanFilenameNormalizerModule? {
        registry.modules.first(where: { $0.id == "korean-filename-normalizer" }) as? KoreanFilenameNormalizerModule
    }

    /// Modules shown to the current app language — language-specific modules
    /// (e.g. the NFD filename normalizer) are hidden for unaffected languages.
    private var relevantModules: [any FeatureModule] {
        registry.modules.filter { $0.isRelevant(to: localizationService.currentLanguage) }
    }

    /// The KFN module, only when it is relevant to the current app language.
    private var relevantKFNModule: KoreanFilenameNormalizerModule? {
        guard let module = kfnModule,
              module.isRelevant(to: localizationService.currentLanguage) else { return nil }
        return module
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label(String(localized: "settings.tab.general"), systemImage: "gearshape") }
            modulesTab
                .tabItem { Label(String(localized: "settings.tab.modules"), systemImage: "puzzlepiece.extension") }
            panelTab
                .tabItem { Label(String(localized: "settings.tab.panel"), systemImage: "menubar.rectangle") }
            aboutTab
                .tabItem { Label(String(localized: "settings.tab.about"), systemImage: "info.circle") }
        }
        .frame(width: 480, height: 440)
        .onAppear {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section {
                Toggle(String(localized: "settings.launch_at_login"), isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(enabled: newValue)
                    }
                    #if DEBUG
                    .disabled(true)
                    .help("Launch at Login is disabled in debug builds to avoid duplicate Login Items. Use a Release build.")
                    #endif

                Button(String(localized: "settings.check_for_updates")) {
                    updaterService.checkForUpdates()
                }
                .disabled(!updaterService.canCheckForUpdates)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Modules Tab

    private var modulesTab: some View {
        Form {
            Section(header: Text(String(localized: "settings.modules.title"))) {
                ForEach(relevantModules, id: \.id) { module in
                    FeatureRowView(
                        module: module,
                        permissionManager: module.requiresAccessibilityPermission ? permissionManager : nil,
                        registry: registry
                    )
                    .listRowInsets(EdgeInsets())
                }
            }

            Section(header: Text(String(localized: "settings.screenshot.title"))) {
                HStack {
                    Text(String(localized: "settings.screenshot.format"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $screenshotFormat) {
                        Text("PNG").tag("png")
                        Text("JPG").tag("jpg")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                    .onChange(of: screenshotFormat) { _, newValue in
                        applyScreenshotFormat(newValue)
                    }
                }

                HStack {
                    Text(String(localized: "settings.screenshot.save_location"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(displayPath(screenshotLocation))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(String(localized: "settings.screenshot.browse")) {
                        chooseScreenshotFolder()
                    }
                }
            }

            if let module = relevantKFNModule {
                Section(header: Text(String(localized: "module.kfn.watched_folders"))) {
                    if module.watchedFolders.isEmpty {
                        Text(String(localized: "module.kfn.no_folders"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(module.watchedFolders, id: \.self) { folder in
                            HStack {
                                Text(displayPath(folder))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button(action: {
                                    module.watchedFolders.removeAll { $0 == folder }
                                }) {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(String(localized: "module.kfn.remove_folder"))
                            }
                        }
                    }

                    Button(String(localized: "module.kfn.add_folder")) {
                        chooseKFNFolder()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Panel Tab

    private var panelTab: some View {
        Form {
            Section {
                ForEach(relevantModules, id: \.id) { module in
                    HStack {
                        Image(systemName: module.icon)
                            .frame(width: 20)
                            .foregroundColor(.secondary)
                        Text(module.name)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { panelConfig.isVisible(module.id) },
                            set: { panelConfig.setVisible(module.id, $0) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                }
            } header: {
                Text(String(localized: "settings.panel_layout.title"))
            } footer: {
                Text(String(localized: "settings.panel_layout.description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - About Tab

    private var aboutTab: some View {
        Form {
            Section {
                VStack(alignment: .center, spacing: 8) {
                    if let icon = NSApp.applicationIconImage {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 64, height: 64)
                    }
                    Text(String(localized: "settings.about.title"))
                        .font(.headline)
                    Text(String(localized: "settings.about.version \(appVersion)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(localized: "settings.about.credits"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section {
                Button(action: {
                    if let url = URL(string: "https://github.com/LuxuryCarrot/macssential/issues/new/choose") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Label(String(localized: "settings.about.feedback"), systemImage: "exclamationmark.bubble")
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            } footer: {
                Text(String(localized: "settings.about.feedback.caption"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button(action: {
                    if let url = URL(string: "https://ko-fi.com/luxurycarrot") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Label(String(localized: "settings.about.kofi"), systemImage: "cup.and.saucer.fill")
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            } footer: {
                Text(String(localized: "settings.about.kofi.caption"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(header: Text(String(localized: "settings.about.licenses.title"))) {
                ForEach(AboutInfo.licenses) { license in
                    DisclosureGroup {
                        ScrollView {
                            Text(license.licenseText)
                                .font(.caption)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 150)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(license.name)
                            Text(license.copyright)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                ForEach(AboutInfo.permissions) { permission in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(localizedKey(permission.nameKey), systemImage: permission.icon)
                        Text(localizedKey(permission.descriptionKey))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(String(localized: "settings.about.permissions.used_by")) \(usedByNames(permission))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text(String(localized: "settings.about.permissions.title"))
            } footer: {
                Text(String(localized: "settings.about.permissions.none_note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func localizedKey(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    private func usedByNames(_ permission: PermissionInfo) -> String {
        permission.usedByModuleKeys
            .map { NSLocalizedString($0, comment: "") }
            .joined(separator: ", ")
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    private func applyScreenshotFormat(_ format: String) {
        runProcess("/usr/bin/defaults", ["write", "com.apple.screencapture", "type", format])
        runProcess("/usr/bin/killall", ["SystemUIServer"])
    }

    private func applyScreenshotLocation(_ path: String) {
        runProcess("/usr/bin/defaults", ["write", "com.apple.screencapture", "location", path])
        runProcess("/usr/bin/killall", ["SystemUIServer"])
    }

    private func chooseScreenshotFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            screenshotLocation = url.path
            applyScreenshotLocation(url.path)
            screenshotModule?.saveFolder = url.path
        }
    }

    private func chooseKFNFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if panel.runModal() == .OK, let url = panel.url,
           let module = kfnModule {
            guard !module.watchedFolders.contains(url.path) else { return }
            module.watchedFolders.append(url.path)
        }
    }

    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func runProcess(_ path: String, _ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("[macssential] Process failed (\(path) \(args)): \(error)")
        }
    }

    private func setLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            UserDefaults.standard.set(enabled, forKey: "com.macssential.app.launchAtLogin")
        } catch {
            // Revert toggle on failure (e.g., unsigned debug builds)
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }
}
