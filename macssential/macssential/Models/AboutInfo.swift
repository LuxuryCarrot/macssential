import Foundation

/// Open-source license entry shown in Settings > About.
/// Names, copyright lines, and license bodies are English-only by design
/// (proper nouns and legal text are not localized).
struct LicenseInfo: Identifiable {
    let id: String
    let name: String
    let copyright: String
    let licenseText: String
}

/// macOS permission entry shown in Settings > About.
/// Name/description are localized via keys; used-by feature names reuse
/// the existing localized module name keys.
struct PermissionInfo: Identifiable {
    let id: String
    let icon: String
    let nameKey: String
    let descriptionKey: String
    let usedByModuleKeys: [String]
}

/// Static informational data for the Settings > About tab. No logic, no I/O.
enum AboutInfo {
    private static func mitLicenseText(copyright: String) -> String {
        """
        MIT License

        \(copyright)

        Permission is hereby granted, free of charge, to any person obtaining a copy \
        of this software and associated documentation files (the "Software"), to deal \
        in the Software without restriction, including without limitation the rights \
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
        copies of the Software, and to permit persons to whom the Software is \
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all \
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE \
        SOFTWARE.
        """
    }

    static let licenses: [LicenseInfo] = [
        LicenseInfo(
            id: "sparkle",
            name: "Sparkle",
            copyright: "Copyright (c) 2006-2013 Andy Matuschak and contributors",
            licenseText: mitLicenseText(
                copyright: "Copyright (c) 2006-2013 Andy Matuschak and contributors"
            )
        )
    ]

    static let permissions: [PermissionInfo] = [
        PermissionInfo(
            id: "accessibility",
            icon: "accessibility",
            nameKey: "settings.about.permissions.accessibility.name",
            descriptionKey: "settings.about.permissions.accessibility.desc",
            usedByModuleKeys: [
                "module.dock_anchor.name",
                "module.scroll_direction.name",
                "module.screenshot_auto_copy.name"
            ]
        ),
        PermissionInfo(
            id: "files",
            icon: "folder",
            nameKey: "settings.about.permissions.files.name",
            descriptionKey: "settings.about.permissions.files.desc",
            usedByModuleKeys: [
                "module.kfn.name",
                "module.screenshot_auto_copy.name"
            ]
        )
    ]
}
