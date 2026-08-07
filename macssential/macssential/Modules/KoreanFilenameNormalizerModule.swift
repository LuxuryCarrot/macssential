import CoreServices
import Foundation
import SwiftUI

/// Monitors user-configured folders via FSEvents and automatically renames
/// any file whose Korean (Hangul) filename is in NFD decomposed form to NFC
/// precomposed form using Darwin.rename() (not FileManager.moveItem, which
/// cannot perform NFD→NFC rename on APFS due to OS-level path normalization).
@Observable
final class KoreanFilenameNormalizerModule: FeatureModule, @unchecked Sendable {
    let id = "korean-filename-normalizer"
    var name: String { String(localized: "module.kfn.name") }
    var moduleDescription: String { String(localized: "module.kfn.description") }
    let icon = "character.cursor.ibeam"
    let isAvailable = true
    let requiresAccessibilityPermission = false

    /// Pure, testable relevance rule: the module is shown when either the app
    /// display language is affected (ko/ja) or any of the user's preferred system
    /// languages is on the NFD-affected list (vi, fr, de, el, ru, …). The app UI
    /// only ships in EN/KO/JA, so system languages are the only signal for
    /// affected users running the app in English.
    static func isRelevant(appLanguage: AppLanguage, systemLanguages: [String]) -> Bool {
        appLanguage.hasNFDFilenameIssue || NFDFilenameIssue.affectsSystemLanguages(systemLanguages)
    }

    func isRelevant(to language: AppLanguage) -> Bool {
        Self.isRelevant(appLanguage: language, systemLanguages: Locale.preferredLanguages)
    }

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "com.macssential.module.kfn.enabled")
            if isEnabled { activate() } else { deactivate() }
        }
    }

    /// Absolute paths of folders to watch. Default: ~/Downloads.
    /// didSet restarts the FSEvents stream to pick up the new folder list.
    var watchedFolders: [String] {
        didSet {
            UserDefaults.standard.set(watchedFolders, forKey: "com.macssential.module.kfn.watchedFolders")
            if isEnabled { startWatching() }
        }
    }

    private var eventStream: FSEventStreamRef?
    private let fsQueue = DispatchQueue(label: "com.macssential.kfn.fsevents", qos: .utility)

    init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: "com.macssential.module.kfn.enabled")
        let defaultFolders = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads").path
        ]
        self.watchedFolders = UserDefaults.standard.stringArray(
            forKey: "com.macssential.module.kfn.watchedFolders") ?? defaultFolders
    }

    func activate() {
        print("[KFN] activate — watching: \(watchedFolders)")
        startWatching()
        fsQueue.async { [weak self] in self?.scanExistingFiles() }
    }
    func deactivate() { stopWatching() }

    /// Live-resource module: quit/permission-revoke must stop the FSEventStream.
    func releaseResources() { deactivate() }

    @MainActor var settingsView: AnyView? {
        AnyView(KoreanFilenameNormalizerSettingsView(module: self))
    }

    // MARK: - FSEvents Lifecycle

    private func startWatching() {
        stopWatching()
        guard !watchedFolders.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let pathsToWatch = watchedFolders as CFArray

        eventStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.fsEventsCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes |
                kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagNoDefer |
                kFSEventStreamCreateFlagIgnoreSelf
            )
        )

        guard let stream = eventStream else { return }
        FSEventStreamSetDispatchQueue(stream, fsQueue)
        FSEventStreamStart(stream)
    }

    private func stopWatching() {
        guard let stream = eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
    }

    // MARK: - Static Callback

    private static let fsEventsCallback: FSEventStreamCallback = {
        _, clientCallBackInfo, numEvents, eventPaths, eventFlags, _ in

        guard let clientCallBackInfo else { return }
        let module = Unmanaged<KoreanFilenameNormalizerModule>
            .fromOpaque(clientCallBackInfo).takeUnretainedValue()

        let paths = unsafeBitCast(eventPaths, to: NSArray.self) as! [String]

        for i in 0..<numEvents {
            let flags = eventFlags[i]
            let path = paths[i]

            let isFile = (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)) != 0
            let isCreatedOrRenamed = (flags & FSEventStreamEventFlags(
                kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed)) != 0
            guard isFile && isCreatedOrRenamed else { continue }

            module.processFileEvent(at: path)
        }
    }

    // MARK: - Initial Scan

    /// Renames existing NFD Korean files in all watched folders.
    /// Uses Darwin opendir/readdir to get raw filesystem bytes (NFD-preserved),
    /// bypassing Foundation URL APIs which may normalize filenames to NFC.
    private func scanExistingFiles() {
        for folder in watchedFolders {
            scanDirectory(atPath: folder)
        }
    }

    private func scanDirectory(atPath dirPath: String) {
        guard let dir = Darwin.opendir(dirPath) else { return }
        defer { Darwin.closedir(dir) }
        while let entry = Darwin.readdir(dir) {
            // d_name is a fixed-size C tuple — rebind to CChar* to read as string.
            // String(cString:) preserves the raw UTF-8 bytes from the filesystem (NFD).
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            guard name != "." && name != ".." && !name.hasPrefix(".") else { continue }
            let fullPath = "\(dirPath)/\(name)"
            switch entry.pointee.d_type {
            case UInt8(DT_DIR):  scanDirectory(atPath: fullPath)
            case UInt8(DT_REG):  processFileEvent(at: fullPath)
            default: break
            }
        }
    }

    // MARK: - File Event Processing

    func processFileEvent(at path: String) {
        // NSString path methods split on '/' without any Unicode normalization,
        // preserving NFD bytes that URL.lastPathComponent may silently NFC-normalize.
        let nsPath = path as NSString
        let filename = nsPath.lastPathComponent

        let scalars = filename.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
        let needsNorm = Self.needsNFCNormalization(filename)
        let affected = Self.containsAffectedScript(filename)
        let state = needsNorm ? "NFD detected" : "already NFC"
        print("[KFN] event: \(filename) | scalars: \(scalars) | \(state) affectedScript=\(affected)")

        guard needsNorm else { return }
        guard affected else { return }

        let normalized = filename.precomposedStringWithCanonicalMapping
        let parentDir = nsPath.deletingLastPathComponent
        let dstPath = "\(parentDir)/\(normalized)"

        // Two-step rename to work around APFS normalization-insensitive lookups.
        // On APFS, rename(NFD_path, NFC_path) is a POSIX no-op: both paths resolve
        // to the same inode, so the kernel returns 0 without updating the stored name.
        // Renaming through an unrelated ASCII temp name breaks the identity check.
        let tmpPath = "\(parentDir)/.kfn_\(UUID().uuidString)"

        // Step 1: NFD path → temp name
        let ret1 = path.withCString { src in
            tmpPath.withCString { tmp in Darwin.rename(src, tmp) }
        }
        guard ret1 == 0 else {
            if errno != ENOENT {
                print("[macssential] KFN rename step1 failed (\(path)): errno=\(errno)")
            }
            return
        }

        // Step 2: temp name → NFC path
        let ret2 = tmpPath.withCString { tmp in
            dstPath.withCString { dst in Darwin.rename(tmp, dst) }
        }
        if ret2 != 0 {
            // Rollback: restore original NFD name so the file isn't left as a hidden temp
            tmpPath.withCString { tmp in
                path.withCString { orig in _ = Darwin.rename(tmp, orig) }
            }
            print("[KFN] rename step2 failed (\(filename)): errno=\(errno)")
        } else {
            print("[KFN] ✓ renamed: \(filename) → \(normalized)")
            // NOTE: Browser file pickers (Chrome/Safari via NSOpenPanel) may still show NFD
            // filenames even after this rename, because Cocoa URL APIs can re-normalize
            // the path. The filesystem bytes are now NFC; this is an OS/browser limitation.
        }
    }

    // MARK: - NFC Detection Helpers

    /// Returns true if the filename's UTF-8 bytes differ from its NFC form.
    /// Uses Data comparison (not String ==) because Swift String == normalizes
    /// before comparing, making NFD and NFC strings always appear equal.
    static func needsNFCNormalization(_ filename: String) -> Bool {
        let nfc = filename.precomposedStringWithCanonicalMapping
        return filename.data(using: .utf8) != nfc.data(using: .utf8)
    }

    /// Returns true if the string contains any script known to be visibly broken
    /// by NFD decomposition: Hangul (Korean), kana with decomposed voicing marks
    /// (Japanese dakuten/handakuten), or combining diacritical marks split off
    /// precomposed Latin/Greek/Cyrillic letters (é → e+U+0301, й → и+U+0306).
    static func containsAffectedScript(_ s: String) -> Bool {
        containsHangul(s) || containsDecomposedKanaVoicing(s) || containsCombiningDiacritics(s)
    }

    /// Returns true if the string contains combining diacritical marks. In a
    /// filename these only appear when NFD decomposed a precomposed letter —
    /// covering Vietnamese, European Latin orthographies, Greek, and Cyrillic.
    /// - U+0300...U+036F: Combining Diacritical Marks
    /// - U+1AB0...U+1AFF: Combining Diacritical Marks Extended
    /// - U+1DC0...U+1DFF: Combining Diacritical Marks Supplement
    static func containsCombiningDiacritics(_ s: String) -> Bool {
        s.unicodeScalars.contains {
            let v = $0.value
            return (0x0300...0x036F).contains(v) ||
                   (0x1AB0...0x1AFF).contains(v) ||
                   (0x1DC0...0x1DFF).contains(v)
        }
    }

    /// Returns true if the string contains a combining voiced/semi-voiced sound
    /// mark (U+3099 / U+309A). These only occur when NFD split a precomposed kana
    /// (が → か+U+3099); precomposed kana carry the mark inside the code point.
    static func containsDecomposedKanaVoicing(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x3099...0x309A).contains($0.value) }
    }

    /// Returns true if the string contains any Hangul characters in any
    /// normalization form. Covers:
    /// - U+AC00...U+D7A3: Hangul Syllables (NFC precomposed)
    /// - U+1100...U+11FF: Hangul Jamo (NFD decomposed)
    /// - U+3130...U+318F: Hangul Compatibility Jamo
    static func containsHangul(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if (0xAC00...0xD7A3).contains(v) ||
               (0x1100...0x11FF).contains(v) ||
               (0x3130...0x318F).contains(v) {
                return true
            }
        }
        return false
    }
}
