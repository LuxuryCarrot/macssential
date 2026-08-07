import SwiftUI

@Observable
final class HiddenFilesModule: FeatureModule {
    let id = "hidden-files"
    var name: String { String(localized: "module.hidden_files.name") }
    var moduleDescription: String { String(localized: "module.hidden_files.description") }
    let icon = "eye"
    let isAvailable = true

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "com.macssential.module.hidden-files.enabled")
            if isEnabled { activate() } else { deactivate() }
        }
    }

    init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: "com.macssential.module.hidden-files.enabled")
    }

    func activate() {
        setHiddenFiles(visible: true)
    }

    func deactivate() {
        setHiddenFiles(visible: false)
    }

    private func setHiddenFiles(visible: Bool) {
        runProcess("/usr/bin/defaults", ["write", "com.apple.finder", "AppleShowAllFiles", "-bool", visible ? "true" : "false"])
        runProcess("/usr/bin/killall", ["Finder"])
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
}
