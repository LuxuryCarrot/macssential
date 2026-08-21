import CoreGraphics
import Foundation

/// Geometry for the menubar dropdown panel, kept pure so the live-resize path can
/// be proven without a status item, a menu, or a screen.
///
/// The panel is an `NSHostingView` installed as an `NSMenuItem.view`, so its height
/// only follows its SwiftUI content if something explicitly resizes the view. That
/// resize is driven by a geometry callback firing during layout, which makes this
/// the natural home for the two guards that keep the loop safe: rejecting degenerate
/// heights, and refusing to act on differences too small to be real.
enum MainPanelSizing {

    /// Fixed panel width, mirroring `MainPanelView`'s own `.frame(width: 280)`.
    /// Content never widens the panel — only its height is content-driven.
    static let width: CGFloat = 280

    /// Floor for a panel whose reported content height is unusable.
    ///
    /// SwiftUI reports zero (and occasionally NaN) during intermediate layout
    /// passes. Honouring such a value would collapse the panel and hide the
    /// Settings/Quit rows, so it is replaced by a height that still shows something
    /// clickable until a real measurement arrives.
    static let minimumHeight: CGFloat = 120

    /// The frame the hosting view should adopt for a given measured content height.
    ///
    /// Clamps to `availableHeight` so a panel full of expanded module settings
    /// cannot grow past the screen and push its own Settings/Quit rows out of reach.
    static func fittedSize(contentHeight: CGFloat, availableHeight: CGFloat) -> CGSize {
        guard contentHeight.isFinite, contentHeight > 0 else {
            return CGSize(width: width, height: minimumHeight)
        }
        // A bogus availableHeight (zero, negative, non-finite) must not be able to
        // clamp the panel away — fall back to the unclamped content height.
        guard availableHeight.isFinite, availableHeight > 0 else {
            return CGSize(width: width, height: contentHeight)
        }
        return CGSize(width: width, height: min(contentHeight, availableHeight))
    }

    /// Whether a resize is worth performing.
    ///
    /// This is the loop breaker (T-HGV-06): resizing the hosting view re-runs SwiftUI
    /// layout, which fires the geometry callback again. Without a tolerance, sub-pixel
    /// differences between the reported and applied size would bounce back and forth
    /// and spin the main thread. Half a point is below anything a user can see and
    /// well above the jitter.
    static func needsResize(current: CGSize, target: CGSize, tolerance: CGFloat = 0.5) -> Bool {
        abs(current.width - target.width) > tolerance
            || abs(current.height - target.height) > tolerance
    }
}
