import CoreGraphics
import AppKit

/// Persistent display fingerprint using vendor+model+serial from CoreGraphics.
///
/// CGDirectDisplayID is transient on Apple Silicon -- it can change across disconnects/reconnects.
/// This struct provides a stable identity for matching displays after reconnection.
/// See: RESEARCH.md Pitfall 1.
struct DisplayIdentifier: Codable, Equatable {
    let vendorNumber: UInt32
    let modelNumber: UInt32
    let serialNumber: UInt32
    let localizedName: String

    /// Creates a DisplayIdentifier from a live CGDirectDisplayID.
    static func from(displayID: CGDirectDisplayID) -> DisplayIdentifier {
        let name = NSScreen.screens.first(where: {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == displayID
        })?.localizedName ?? "Unknown"

        return DisplayIdentifier(
            vendorNumber: CGDisplayVendorNumber(displayID),
            modelNumber: CGDisplayModelNumber(displayID),
            serialNumber: CGDisplaySerialNumber(displayID),
            localizedName: name
        )
    }

    /// Finds a currently connected display matching this fingerprint.
    /// Returns nil if no matching display is connected.
    func findCurrentDisplayID() -> CGDirectDisplayID? {
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? CGDirectDisplayID else { continue }
            let candidate = DisplayIdentifier.from(displayID: id)
            if candidate.vendorNumber == vendorNumber &&
               candidate.modelNumber == modelNumber &&
               candidate.serialNumber == serialNumber {
                return id
            }
        }
        return nil
    }
}
