// Builds the BetterDPI app icon from logo.png.
//
// logo.png is a screenshot of the icon (a monitor showing "HiDPI" with a
// magnifier and a "2x" badge, inside a rounded square) on a dark background,
// with a caption underneath and slightly stretched vertically.
//
// macOS 26 and later shows an .icns icon in a grey rounded tile unless the
// artwork is a full-bleed opaque square, which the system then masks to its own
// icon shape (verified: transparent, squircle-clipped and inset variants were
// all tiled, and so was an opaque square saved with an alpha channel; the PNGs
// must have no alpha channel at all). So this composes a full-bleed 1024×1024 square: a dark gradient
// taken from the icon's interior, the monitor and magnifier blended in with soft
// edges, and the "2x" badge redrawn whole, inside the system's corner curve.
//
// Usage: swift tools/make_icon.swift logo.png Resources
import AppKit
import CoreImage

// Geometry measured in logo.png (pixels, top-left origin). Re-measure if the logo changes.
let monitorRect = CGRect(x: 138, y: 146, width: 390, height: 324)   // screen, stand and magnifier
let badgeCenter = CGPoint(x: 494, y: 126)                           // "2x" badge
let badgeRadius: CGFloat = 63
let topColor = CIColor(red: 0x46 / 255.0, green: 0x52 / 255.0, blue: 0x5E / 255.0)     // interior, top
let bottomColor = CIColor(red: 0x1F / 255.0, green: 0x24 / 255.0, blue: 0x2A / 255.0)  // interior, bottom

// Placement on the 1024 canvas (top-left origin), chosen so the badge stays
// inside the rounded corner macOS applies.
let canvas: CGFloat = 1024
let scale: CGFloat = 1.95
let monitorOrigin = CGPoint(x: (canvas - monitorRect.width * scale) / 2,
                            y: (canvas - monitorRect.height * scale) / 2 + 30)

let args = CommandLine.arguments
guard args.count == 3, let logo = NSImage(contentsOfFile: args[1]),
      let source = logo.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("usage: swift make_icon.swift logo.png OUTPUT_DIR\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: args[2], isDirectory: true)
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ci = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb])

/// Logo pixel (top-left origin) -> canvas point in Core Image space (bottom-left origin).
func place(_ p: CGPoint) -> CGPoint {
    CGPoint(x: monitorOrigin.x + (p.x - monitorRect.minX) * scale,
            y: canvas - (monitorOrigin.y + (p.y - monitorRect.minY) * scale))
}

/// A crop of the logo, scaled and positioned on the canvas.
func placedCrop(_ r: CGRect) -> CIImage {
    let img = CIImage(cgImage: source.cropping(to: r)!)
    let origin = place(CGPoint(x: r.minX, y: r.maxY))   // bottom-left corner of the crop
    return img.transformed(by: CGAffineTransform(scaleX: scale, y: scale)
        .concatenating(CGAffineTransform(translationX: origin.x, y: origin.y)))
}

/// White shape on black, softened by `feather` points: a blend mask.
func mask(_ path: CGPath, feather: CGFloat) -> CIImage {
    let ctx = CGContext(data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.setFillColor(gray: 0, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.addPath(path)
    ctx.fillPath()
    let m = CIImage(cgImage: ctx.makeImage()!)
    return feather > 0 ? m.clampedToExtent().applyingGaussianBlur(sigma: feather).cropped(to: m.extent) : m
}

let bounds = CGRect(x: 0, y: 0, width: canvas, height: canvas)
let background = CIFilter(name: "CILinearGradient", parameters: [
    "inputPoint0": CIVector(x: 0, y: canvas), "inputColor0": topColor,
    "inputPoint1": CIVector(x: 0, y: 0), "inputColor1": bottomColor,
])!.outputImage!.cropped(to: bounds)

// Monitor and magnifier, edges faded into the background so no seam shows.
let monitor = placedCrop(monitorRect)
let monitorMask = mask(CGPath(roundedRect: monitor.extent.insetBy(dx: 22, dy: 22), cornerWidth: 40, cornerHeight: 40,
                              transform: nil), feather: 12)
var icon = monitor.applyingFilter("CIBlendWithMask", parameters: [
    kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: monitorMask,
]).cropped(to: bounds)

// The whole badge, at the same mapping, so it covers the part of it inside the monitor crop.
let badgeSource = CGRect(x: badgeCenter.x - badgeRadius, y: badgeCenter.y - badgeRadius,
                         width: 2 * badgeRadius, height: 2 * badgeRadius)
let c = place(badgeCenter)
let r = badgeRadius * scale
let badgeMask = mask(CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil),
                     feather: 1)
icon = placedCrop(badgeSource).applyingFilter("CIBlendWithMask", parameters: [
    kCIInputBackgroundImageKey: icon, kCIInputMaskImageKey: badgeMask,
]).cropped(to: bounds)

/// The image at `px`×`px` with no alpha channel (see the note at the top).
func opaque(_ image: CGImage, size px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url)
}

let master = opaque(ci.createCGImage(icon, from: bounds, format: .RGBA8, colorSpace: srgb)!, size: Int(canvas))

let iconset = outDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try writePNG(master, to: outDir.appendingPathComponent("AppIcon-1024.png"))
for base in [16, 32, 128, 256, 512] {
    for s in [1, 2] {
        let px = base * s
        let name = s == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try writePNG(px == 1024 ? master : opaque(master, size: px), to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
try FileManager.default.removeItem(at: iconset)
print("wrote \(outDir.path)/AppIcon.icns and AppIcon-1024.png")
