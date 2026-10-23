import CoreImage
import Foundation
import QuartzCore

/// Image adjustments shared by the compositor filter layer and Video Filter Windows.
/// Neutral values leave the image unchanged.
struct FilterSettings: Codable, Equatable {
    var brightness: Double = 0      // -1...1, additive
    var contrast: Double = 1        // 0...2
    var saturation: Double = 1      // 0 = grayscale ... 2
    var hue: Double = 0             // degrees, -180...180
    var blur: Double = 0            // radius in points, 0...30
    var sepia: Double = 0           // 0...1
    var red: Double = 1             // RGB gain, 0...2
    var green: Double = 1
    var blue: Double = 1
    var invert = false
    /// Core Image only effect (Video Filter Windows).
    var effect: Effect = .none
    var effectAmount: Double = 0.5  // 0...1, mapped to each effect's own range
    /// Custom 3D LUT from the LUT library (Video Filter Windows).
    var lutID: UUID?

    /// Effects that only the Core Image path can render.
    enum Effect: String, Codable, CaseIterable, Identifiable {
        case none, sharpen, unsharpMask, vignette, vibrance, noiseReduction, median
        case pixellate, hexagonalPixellate, crystallize, pointillize, posterize
        case bloom, gloom, motionBlur, edges, edgeWork, comic, thermal, xRay
        case dotScreen, lineScreen, hatchedScreen, cmykHalftone
        case photoNoir, photoChrome, photoFade, photoInstant, photoProcess, photoTransfer

        var id: String { rawValue }

        var title: String {
            switch self {
            case .none: return "None"
            case .xRay: return "X-Ray"
            case .cmykHalftone: return "CMYK Halftone"
            default:
                return rawValue.replacingOccurrences(of: "([A-Z])", with: " $1", options: .regularExpression)
                    .capitalized
            }
        }

        /// Core Image filter name, the numeric input it drives and that input's range.
        var spec: (name: String, key: String?, range: ClosedRange<Double>) {
            switch self {
            case .none: return ("", nil, 0...0)
            case .sharpen: return ("CISharpenLuminance", kCIInputSharpnessKey, 0...2)
            case .unsharpMask: return ("CIUnsharpMask", kCIInputIntensityKey, 0...2)
            case .vignette: return ("CIVignette", kCIInputIntensityKey, 0...2)
            case .vibrance: return ("CIVibrance", "inputAmount", -1...1)
            case .noiseReduction: return ("CINoiseReduction", "inputNoiseLevel", 0...0.1)
            case .median: return ("CIMedianFilter", nil, 0...0)
            case .pixellate: return ("CIPixellate", kCIInputScaleKey, 2...60)
            case .hexagonalPixellate: return ("CIHexagonalPixellate", kCIInputScaleKey, 2...60)
            case .crystallize: return ("CICrystallize", kCIInputRadiusKey, 2...60)
            case .pointillize: return ("CIPointillize", kCIInputRadiusKey, 2...30)
            case .posterize: return ("CIColorPosterize", "inputLevels", 2...16)
            case .bloom: return ("CIBloom", kCIInputIntensityKey, 0...2)
            case .gloom: return ("CIGloom", kCIInputIntensityKey, 0...2)
            case .motionBlur: return ("CIMotionBlur", kCIInputRadiusKey, 0...40)
            case .edges: return ("CIEdges", kCIInputIntensityKey, 0...10)
            case .edgeWork: return ("CIEdgeWork", kCIInputRadiusKey, 1...10)
            case .comic: return ("CIComicEffect", nil, 0...0)
            case .thermal: return ("CIThermal", nil, 0...0)
            case .xRay: return ("CIXRay", nil, 0...0)
            case .dotScreen: return ("CIDotScreen", kCIInputWidthKey, 2...30)
            case .lineScreen: return ("CILineScreen", kCIInputWidthKey, 2...30)
            case .hatchedScreen: return ("CIHatchedScreen", kCIInputWidthKey, 2...30)
            case .cmykHalftone: return ("CICMYKHalftone", kCIInputWidthKey, 2...30)
            case .photoNoir: return ("CIPhotoEffectNoir", nil, 0...0)
            case .photoChrome: return ("CIPhotoEffectChrome", nil, 0...0)
            case .photoFade: return ("CIPhotoEffectFade", nil, 0...0)
            case .photoInstant: return ("CIPhotoEffectInstant", nil, 0...0)
            case .photoProcess: return ("CIPhotoEffectProcess", nil, 0...0)
            case .photoTransfer: return ("CIPhotoEffectTransfer", nil, 0...0)
            }
        }

        var hasAmount: Bool { spec.key != nil }
    }

    // MARK: - Compositor path (CAFilter on a CABackdropLayer)

    /// CAFilters for the compositor overlay. Effects and LUTs are not available
    /// here: the window server only runs CAFilter types on backdrop layers.
    func caFilters(scale: CGFloat) -> [Any] {
        var out: [Any] = []
        func add(_ type: String, _ values: [String: Any]) {
            guard let f = BDMakeCAFilter(type) as? NSObject else { return }
            for (k, v) in values { f.setValue(v, forKey: k) }
            out.append(f)
        }
        if let m = colorMatrix() {
            var floats = m.map(Float.init)
            let value = NSValue(bytes: &floats, objCType: "{CAColorMatrix=ffffffffffffffffffff}")
            add("colorMatrix", ["inputColorMatrix": value])
        }
        if saturation != 1 { add("colorSaturate", ["inputAmount": saturation]) }
        if brightness != 0 { add("colorBrightness", ["inputAmount": brightness]) }
        if contrast != 1 { add("colorContrast", ["inputAmount": contrast]) }
        if hue != 0 { add("colorHueRotate", ["inputAngle": hue * .pi / 180]) }
        if blur > 0 { add("gaussianBlur", ["inputRadius": blur * Double(scale)]) }
        if invert { add("colorInvert", [:]) }
        return out
    }

    /// Row-major 4×5 matrix combining sepia and RGB gain, or nil when neutral.
    private func colorMatrix() -> [Double]? {
        guard sepia > 0 || red != 1 || green != 1 || blue != 1 else { return nil }
        let sepiaRows: [[Double]] = [[0.393, 0.769, 0.189], [0.349, 0.686, 0.168], [0.272, 0.534, 0.131]]
        let gains = [red, green, blue]
        var m = [Double](repeating: 0, count: 20)
        for row in 0..<3 {
            for col in 0..<3 {
                let identity: Double = row == col ? 1 : 0
                m[row * 5 + col] = ((1 - sepia) * identity + sepia * sepiaRows[row][col]) * gains[row]
            }
        }
        m[18] = 1   // alpha passes through
        return m
    }

    // MARK: - Core Image path (Video Filter Windows)

    func apply(to image: CIImage, pixelsPerPoint: CGFloat, lut: [String: Any]?) -> CIImage {
        let extent = image.extent
        var img = image
        if let m = colorMatrix() {
            img = img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: m[0], y: m[1], z: m[2], w: 0),
                "inputGVector": CIVector(x: m[5], y: m[6], z: m[7], w: 0),
                "inputBVector": CIVector(x: m[10], y: m[11], z: m[12], w: 0),
            ])
        }
        if saturation != 1 || brightness != 0 || contrast != 1 {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: saturation, kCIInputBrightnessKey: brightness,
                kCIInputContrastKey: contrast,
            ])
        }
        if hue != 0 { img = img.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: hue * .pi / 180]) }
        if blur > 0 {
            img = img.clampedToExtent()
                .applyingGaussianBlur(sigma: blur * Double(pixelsPerPoint) / 2)
                .cropped(to: extent)
        }
        if effect != .none, let f = CIFilter(name: effect.spec.name) {
            f.setDefaults()
            if let key = effect.spec.key {
                let r = effect.spec.range
                var v = r.lowerBound + (r.upperBound - r.lowerBound) * effectAmount
                if [kCIInputScaleKey, kCIInputRadiusKey, kCIInputWidthKey].contains(key) { v *= Double(pixelsPerPoint) }
                f.setValue(v, forKey: key)
            }
            if f.inputKeys.contains(kCIInputCenterKey) {
                f.setValue(CIVector(x: extent.midX, y: extent.midY), forKey: kCIInputCenterKey)
            }
            f.setValue(img.clampedToExtent(), forKey: kCIInputImageKey)
            img = (f.outputImage ?? img).cropped(to: extent)
        }
        if let lut { img = img.applyingFilter("CIColorCubeWithColorSpace", parameters: lut) }
        if invert {
            // Invert gamma-encoded values (as the compositor does), not linear light.
            img = img.applyingFilter("CILinearToSRGBToneCurve").applyingFilter("CIColorInvert")
                .applyingFilter("CISRGBToneCurveToLinear")
        }
        return img
    }
}

extension FilterSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FilterSettings()
        self.init(brightness: c.value(.brightness, or: d.brightness), contrast: c.value(.contrast, or: d.contrast),
                  saturation: c.value(.saturation, or: d.saturation), hue: c.value(.hue, or: d.hue),
                  blur: c.value(.blur, or: d.blur), sepia: c.value(.sepia, or: d.sepia),
                  red: c.value(.red, or: d.red), green: c.value(.green, or: d.green), blue: c.value(.blue, or: d.blue),
                  invert: c.value(.invert, or: d.invert), effect: c.value(.effect, or: d.effect),
                  effectAmount: c.value(.effectAmount, or: d.effectAmount), lutID: c.value(.lutID, or: d.lutID))
    }
}
