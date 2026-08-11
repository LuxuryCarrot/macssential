import SwiftUI

/// A macOS-style switch ToggleStyle with EXPLICIT colors.
///
/// Why this exists: the panel's SwiftUI views are hosted inside an NSMenu via
/// NSHostingView. NSMenu windows are never the key window, so AppKit treats
/// them as inactive and the native `.switch` style desaturates its accent
/// tint — an ON switch renders gray, indistinguishable from OFF. This style
/// draws literal RGB colors (system-blue ON, gray OFF, white knob) that are
/// immune to inactive-window desaturation. Never use `.tint`/`.accentColor`
/// here — those are exactly what gets desaturated.
///
/// Settings-window toggles live in a real key window and should keep the
/// native `.switch` style; apply this style only in panel contexts.
struct PanelSwitchToggleStyle: ToggleStyle {
    enum Size {
        /// Matches `.switch` + `.controlSize(.small)` footprint (36x20).
        case small
        /// Matches `.switch` + `.controlSize(.mini)` footprint (30x16).
        case mini

        var trackWidth: CGFloat {
            switch self {
            case .small: return 36
            case .mini: return 30
            }
        }

        var trackHeight: CGFloat {
            switch self {
            case .small: return 20
            case .mini: return 16
            }
        }

        var knobDiameter: CGFloat {
            switch self {
            case .small: return 16
            case .mini: return 12
            }
        }
    }

    var size: Size = .small

    /// Explicit system-blue (10, 132, 255) — NOT `.accentColor`, which
    /// desaturates in NSMenu-hosted (inactive) windows.
    private static let onColor = Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255)
    private static let offColor = Color(white: 0.42)

    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            switchGraphic(configuration: configuration)
        }
    }

    private func switchGraphic(configuration: Configuration) -> some View {
        ZStack {
            Capsule()
                .fill(configuration.isOn ? Self.onColor : Self.offColor)

            Circle()
                .fill(Color.white)
                .frame(width: size.knobDiameter, height: size.knobDiameter)
                .frame(
                    maxWidth: .infinity,
                    alignment: configuration.isOn ? .trailing : .leading
                )
                .padding(2)
        }
        .frame(width: size.trackWidth, height: size.trackHeight)
        .animation(.easeInOut(duration: 0.18), value: configuration.isOn)
        .contentShape(Rectangle())
        .onTapGesture {
            configuration.isOn.toggle()
        }
    }
}
