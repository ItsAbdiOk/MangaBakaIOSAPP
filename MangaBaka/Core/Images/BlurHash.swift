import CoreGraphics
import Foundation
import UIKit

/// Decodes the BlurHash strings the API supplies with every cover.
///
/// Worth doing rather than showing a flat rectangle: the placeholder already
/// carries the cover's real colours, so a loading grid looks like the grid it is
/// about to become instead of a wall of grey. The hash is around 30 bytes and
/// arrives in the same response as the metadata, so it costs no extra request.
///
/// Implementation follows the reference algorithm at github.com/woltapp/blurhash.
enum BlurHash {
    /// Decodes to a small image, which is then scaled up by the view. Decoding
    /// at full size would be wasted work — the result is a blur either way.
    static func image(from hash: String, size: CGSize = CGSize(width: 32, height: 32),
                      punch: Float = 1) -> UIImage? {
        guard let parsed = parse(hash, punch: punch) else { return nil }
        return render(parsed, size: size)
    }

    /// An RGB triple in linear space. A named type rather than a tuple, which
    /// also reads better than `.0`, `.1`, `.2` at every use site.
    private struct Colour {
        var red: Float
        var green: Float
        var blue: Float
    }

    private struct Parsed {
        let componentsX: Int
        let componentsY: Int
        let colours: [Colour]
    }

    private static func parse(_ hash: String, punch: Float) -> Parsed? {
        guard hash.count >= 6 else { return nil }

        let characters = Array(hash)
        guard let sizeFlag = decode83(String(characters[0])) else { return nil }
        let componentsX = (sizeFlag % 9) + 1
        let componentsY = (sizeFlag / 9) + 1
        guard hash.count == 4 + 2 * componentsX * componentsY else { return nil }

        guard let quantisedMaximum = decode83(String(characters[1])) else { return nil }
        let maximumValue = Float(quantisedMaximum + 1) / 166

        var colours = [Colour](repeating: Colour(red: 0, green: 0, blue: 0),
                               count: componentsX * componentsY)
        for index in colours.indices {
            if index == 0 {
                guard let value = decode83(String(characters[2..<6])) else { return nil }
                colours[index] = decodeDC(value)
            } else {
                let start = 4 + index * 2
                guard let value = decode83(String(characters[start..<start + 2])) else { return nil }
                colours[index] = decodeAC(value, maximumValue: maximumValue * punch)
            }
        }
        return Parsed(componentsX: componentsX, componentsY: componentsY, colours: colours)
    }

    private static func render(_ parsed: Parsed, size: CGSize) -> UIImage? {
        let componentsX = parsed.componentsX
        let componentsY = parsed.componentsY
        let colours = parsed.colours
        let width = Int(size.width)
        let height = Int(size.height)
        let bytesPerRow = width * 3
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        for y in 0..<height {
            for x in 0..<width {
                var red: Float = 0
                var green: Float = 0
                var blue: Float = 0
                for row in 0..<componentsY {
                    for column in 0..<componentsX {
                        let basis = cos(Float.pi * Float(x) * Float(column) / Float(width))
                            * cos(Float.pi * Float(y) * Float(row) / Float(height))
                        let colour = colours[column + row * componentsX]
                        red += colour.red * basis
                        green += colour.green * basis
                        blue += colour.blue * basis
                    }
                }
                let offset = 3 * x + y * bytesPerRow
                pixels[offset] = UInt8(linearTosRGB(red))
                pixels[offset + 1] = UInt8(linearTosRGB(green))
                pixels[offset + 2] = UInt8(linearTosRGB(blue))
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                  width: width, height: height,
                  bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: bytesPerRow,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              )
        else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Base 83

    private static let alphabet = Array(
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~"
    )

    private static func decode83(_ string: String) -> Int? {
        var value = 0
        for character in string {
            guard let digit = alphabet.firstIndex(of: character) else { return nil }
            value = value * 83 + digit
        }
        return value
    }

    private static func decodeDC(_ value: Int) -> Colour {
        Colour(
            red: sRGBToLinear((value >> 16) & 255),
            green: sRGBToLinear((value >> 8) & 255),
            blue: sRGBToLinear(value & 255)
        )
    }

    private static func decodeAC(_ value: Int, maximumValue: Float) -> Colour {
        let red = Float(value / (19 * 19))
        let green = Float((value / 19) % 19)
        let blue = Float(value % 19)
        return Colour(
            red: signPow((red - 9) / 9, 2) * maximumValue,
            green: signPow((green - 9) / 9, 2) * maximumValue,
            blue: signPow((blue - 9) / 9, 2) * maximumValue
        )
    }

    private static func sRGBToLinear(_ value: Int) -> Float {
        let normalised = Float(value) / 255
        return normalised <= 0.04045
            ? normalised / 12.92
            : pow((normalised + 0.055) / 1.055, 2.4)
    }

    private static func linearTosRGB(_ value: Float) -> Int {
        let clamped = max(0, min(1, value))
        return clamped <= 0.0031308
            ? Int(clamped * 12.92 * 255 + 0.5)
            : Int((1.055 * pow(clamped, 1 / 2.4) - 0.055) * 255 + 0.5)
    }

    private static func signPow(_ value: Float, _ exponent: Float) -> Float {
        (value < 0 ? -1 : 1) * pow(abs(value), exponent)
    }
}
