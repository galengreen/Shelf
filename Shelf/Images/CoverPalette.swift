import SwiftUI
import UIKit

/// Colours sampled from a cover: a 3×3 grid for the player's mesh-gradient background plus an
/// overall average. Computed once from the smallest cached thumbnail (a few microseconds), and the
/// resulting gradient is static, so the player background costs nothing per frame.
nonisolated struct CoverPalette: Sendable, Equatable {
    struct RGB: Sendable, Equatable {
        var r: Double, g: Double, b: Double
    }

    let grid: [RGB]   // 9 colours, row-major
    let average: RGB

    init?(imageData: Data) {
        guard let image = ImagePipeline.downsample(imageData, to: 48)?.cgImage else { return nil }
        guard let grid = CoverPalette.sample(image, size: 3), grid.count == 9,
              let avg = CoverPalette.sample(image, size: 1)?.first else { return nil }
        self.grid = grid
        self.average = avg
    }

    private static func sample(_ image: CGImage, size: Int) -> [RGB]? {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else { return nil }
        return stride(from: 0, to: pixels.count, by: 4).map {
            RGB(r: Double(pixels[$0]) / 255, g: Double(pixels[$0 + 1]) / 255, b: Double(pixels[$0 + 2]) / 255)
        }
    }
}

extension CoverPalette.RGB {
    /// Tone a sampled colour into a rich, dark background that keeps white text legible.
    func backgroundTone(brightness cap: Double = 0.42) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
        UIColor(red: r, green: g, blue: b, alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: nil)
        let saturation = min(Double(s), 0.65) * 0.9
        let brightness = min(max(Double(v) * 0.7, 0.14), cap)
        return Color(hue: Double(h), saturation: saturation, brightness: brightness)
    }

    var color: Color { Color(red: r, green: g, blue: b) }
}

extension CoverPalette {
    var meshColors: [Color] {
        grid.enumerated().map { index, rgb in
            // Darker towards the bottom where the controls sit.
            let row = index / 3
            return rgb.backgroundTone(brightness: [0.48, 0.38, 0.24][row])
        }
    }

    var baseColor: Color { average.backgroundTone(brightness: 0.3) }

    static let fallbackMesh: [Color] = [
        Color(hue: 0.07, saturation: 0.45, brightness: 0.38), Color(hue: 0.06, saturation: 0.4, brightness: 0.33), Color(hue: 0.08, saturation: 0.35, brightness: 0.36),
        Color(hue: 0.06, saturation: 0.4, brightness: 0.3), Color(hue: 0.07, saturation: 0.38, brightness: 0.27), Color(hue: 0.05, saturation: 0.42, brightness: 0.28),
        Color(hue: 0.06, saturation: 0.35, brightness: 0.2), Color(hue: 0.07, saturation: 0.3, brightness: 0.18), Color(hue: 0.06, saturation: 0.32, brightness: 0.19),
    ]
}
