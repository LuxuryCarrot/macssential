#!/usr/bin/env swift
//
// render-menubar-icon.swift
//
// Deterministic generator for the macssential menu bar template icon:
// a 6-spoke geometric asterisk (✱) built from 3 crossing rounded capsules.
//
// Usage:
//   swift scripts/render-menubar-icon.swift
//
// Emits:
//   macssential/macssential/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon.png     (22x22)
//   macssential/macssential/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon@2x.png  (44x44)
//
// The artwork is pure black on transparent; the asset catalog's
// template-rendering-intent (plus isTemplate=true in AppDelegate) handles
// automatic light/dark menu bar adaptation.

import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Design parameters (22pt design space)

let canvasSize: CGFloat = 22.0        // pt — menu bar icon canvas
let markLength: CGFloat = 16.0        // pt — capsule length (>= 3pt margin on all sides)
let markThickness: CGFloat = 2.6      // pt — capsule thickness
let spokeAngles: [CGFloat] = [0, 60, 120].map { $0 * .pi / 180 }  // vertical + 60° + 120°

let center = CGPoint(x: canvasSize / 2, y: canvasSize / 2)

// MARK: - Geometry

/// Vertical capsule centered at `center`: fully-rounded rect spanning
/// y in [center.y - length/2, center.y + length/2], width = thickness.
func capsulePath() -> CGPath {
    let rect = CGRect(
        x: center.x - markThickness / 2,
        y: center.y - markLength / 2,
        width: markThickness,
        height: markLength
    )
    return CGPath(
        roundedRect: rect,
        cornerWidth: markThickness / 2,
        cornerHeight: markThickness / 2,
        transform: nil
    )
}

// MARK: - Rendering

func render(scale: Int) -> CGImage {
    let pixels = Int(canvasSize) * scale
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Failed to create CGContext for scale \(scale)x")
    }

    context.setShouldAntialias(true)
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))

    let capsule = capsulePath()
    for angle in spokeAngles {
        context.saveGState()
        // Rotate about the canvas center: translate → rotate → translate back.
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: angle)
        context.translateBy(x: -center.x, y: -center.y)
        context.addPath(capsule)
        context.fillPath()
        context.restoreGState()
    }

    guard let image = context.makeImage() else {
        fatalError("Failed to make CGImage for scale \(scale)x")
    }
    return image
}

// MARK: - PNG output

/// Deterministic provenance note embedded as a PNG tEXt Description chunk.
let provenanceNote = """
macssential menu bar template icon — 6-spoke geometric asterisk (three crossing \
rounded capsules, 16pt length, 2.6pt thickness, 22pt design space). Generated \
deterministically by scripts/render-menubar-icon.swift; do not hand-edit — \
re-run the script to regenerate both 1x and 2x assets.
"""

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        fatalError("Failed to create PNG destination at \(url.path)")
    }
    let properties: [CFString: Any] = [
        kCGImagePropertyPNGDictionary: [
            kCGImagePropertyPNGDescription: provenanceNote
        ]
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("Failed to write PNG at \(url.path)")
    }
}

// MARK: - Sanity metric

/// Ratio of pixels with alpha above `threshold` over total pixels.
/// threshold 0 → any coverage (includes anti-aliased fringe);
/// threshold 127 → solid pixels only (closer to geometric coverage).
func filledPixelRatio(of image: CGImage, alphaAbove threshold: UInt8 = 0) -> Double {
    let width = image.width
    let height = image.height
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return 0 }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let data = context.data else { return 0 }
    let buffer = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
    var filled = 0
    for i in 0..<(width * height) where buffer[i * 4 + 3] > threshold {
        filled += 1
    }
    return Double(filled) / Double(width * height)
}

// MARK: - Main

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
// scripts/render-menubar-icon.swift → repo root is the script's parent's parent.
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let imagesetURL = repoRoot
    .appendingPathComponent("macssential/macssential/Assets.xcassets/MenuBarIcon.imageset")

guard FileManager.default.fileExists(atPath: imagesetURL.path) else {
    fatalError("Imageset directory not found: \(imagesetURL.path)")
}

let outputs: [(scale: Int, filename: String)] = [
    (1, "MenuBarIcon.png"),
    (2, "MenuBarIcon@2x.png"),
]

for output in outputs {
    let image = render(scale: output.scale)
    let url = imagesetURL.appendingPathComponent(output.filename)
    writePNG(image, to: url)
    let anyCoverage = filledPixelRatio(of: image)
    let solid = filledPixelRatio(of: image, alphaAbove: 127)
    print(String(
        format: "%@ — %dx%d px, filled-pixel ratio: %.3f (alpha>0), %.3f (solid)",
        output.filename, image.width, image.height, anyCoverage, solid
    ))
}
