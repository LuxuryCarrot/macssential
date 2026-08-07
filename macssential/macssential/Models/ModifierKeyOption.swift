import CoreGraphics

/// User-configurable modifier key for temporarily bypassing Dock Anchor event blocking.
///
/// When the selected modifier key is held during mouse movement, all events pass through
/// and the Dock can move freely between monitors. Per D-06.
///
/// Note: Fn key is excluded -- it is NOT detectable via CGEventFlags in CGEventTap callbacks.
/// The Fn key is consumed by the system before reaching the event tap. See RESEARCH.md Pitfall 2.
enum ModifierKeyOption: String, CaseIterable, Codable {
    case option = "option"
    case control = "control"
    case command = "command"

    /// Human-readable name with Unicode modifier symbol.
    var displayName: String {
        switch self {
        case .option: return "Option (\u{2325})"
        case .control: return "Control (\u{2303})"
        case .command: return "Command (\u{2318})"
        }
    }

    /// Compact symbol-only label for tight layouts (segmented control in the
    /// 280pt menu bar panel, where three full displayName segments don't fit).
    var symbol: String {
        switch self {
        case .option: return "\u{2325}"
        case .control: return "\u{2303}"
        case .command: return "\u{2318}"
        }
    }

    /// CGEventFlags mask for checking this modifier in CGEvent callbacks.
    var eventFlags: CGEventFlags {
        switch self {
        case .option: return .maskAlternate
        case .control: return .maskControl
        case .command: return .maskCommand
        }
    }

    /// UserDefaults key for persisting the selected modifier key. Per D-10.
    static let defaultsKey = "com.macssential.module.dock-anchor.modifier"
}
