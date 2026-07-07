import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum LauncherIcon {
    public static let bundleIconName = "msl-distro"

    public static func writeFallbackICNS(name: String, to url: URL) throws {
        guard Registry.isValidName(name) else {
            throw MSLError.invalidArgument("invalid distro name: \(name)")
        }
        let png = try fallbackPNG(name: name)
        try writeICNS(pngData: png, to: url)
    }

    public static func writeICNS(pngData: Data, to url: URL) throws {
        guard pngData.count < 100 * 1024 * 1024 else {
            throw MSLError.configuration("icon PNG is too large")
        }
        guard pngData.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) else {
            throw MSLError.configuration("icon data is not PNG")
        }
        var data = Data()
        appendASCII("icns", to: &data)
        appendUInt32(UInt32(16 + pngData.count), to: &data)
        appendASCII("ic10", to: &data)
        appendUInt32(UInt32(8 + pngData.count), to: &data)
        data.append(pngData)
        try data.write(to: url, options: .atomic)
    }

    public static func validateICNS(at url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.starts(with: [0x69, 0x63, 0x6e, 0x73]) else {
            throw MSLError.configuration("icon is not an ICNS file: \(url.path)")
        }
    }

    private static func fallbackPNG(name: String) throws -> Data {
        let side = 1024
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            throw MSLError.io("cannot create icon bitmap")
        }
        drawBackground(context: context, side: side, name: name)
        drawInitials(context: context, side: side, text: initials(for: name))
        guard let image = context.makeImage() else {
            throw MSLError.io("cannot render icon bitmap")
        }
        return try pngData(for: image)
    }

    private static func drawBackground(context: CGContext, side: Int, name: String) {
        let palette = colors(for: name)
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        context.setFillColor(palette.background)
        context.fill(rect)
        let inset = CGFloat(side) * 0.09
        let panel = rect.insetBy(dx: inset, dy: inset)
        let path = CGMutablePath()
        path.addRoundedRect(
            in: panel, cornerWidth: CGFloat(side) * 0.18, cornerHeight: CGFloat(side) * 0.18)
        context.addPath(path)
        context.setFillColor(palette.foreground.copy(alpha: 0.16) ?? palette.foreground)
        context.fillPath()
        context.setLineWidth(CGFloat(side) * 0.035)
        context.addPath(path)
        context.setStrokeColor(palette.foreground.copy(alpha: 0.45) ?? palette.foreground)
        context.strokePath()
    }

    private static func drawInitials(context: CGContext, side: Int, text: String) {
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, CGFloat(side) * 0.42, nil)
        let attrs =
            [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor(
                    red: 1, green: 1, blue: 1, alpha: 0.94),
            ] as CFDictionary
        guard let attributed = CFAttributedStringCreate(nil, text as CFString, attrs) else {
            return
        }
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        let originX = (CGFloat(side) - bounds.width) / 2 - bounds.minX
        let originY = (CGFloat(side) - bounds.height) / 2 - bounds.minY - CGFloat(side) * 0.015
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: originX, y: originY)
        CTLineDraw(line, context)
    }

    private static func pngData(for image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil)
        else {
            throw MSLError.io("cannot create icon PNG encoder")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw MSLError.io("cannot encode icon PNG")
        }
        return data as Data
    }

    private static func initials(for name: String) -> String {
        let parts = name.split(separator: "-").filter { !$0.isEmpty }
        let letters = parts.prefix(2).compactMap { $0.first?.uppercased() }.joined()
        if !letters.isEmpty { return letters }
        return String(name.prefix(1)).uppercased()
    }

    private static func colors(for name: String) -> (background: CGColor, foreground: CGColor) {
        let hash = stableHash(name)
        let hue = CGFloat(hash % 360) / 360
        let background = hsb(hue: hue, saturation: 0.64, brightness: 0.46)
        let foreground = hsb(hue: hue, saturation: 0.34, brightness: 0.95)
        return (background, foreground)
    }

    private static func stableHash(_ value: String) -> UInt32 {
        var hash: UInt32 = 5381
        for byte in value.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt32(byte)
        }
        return hash
    }

    private static func hsb(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) -> CGColor {
        let wheelIndex = floor(hue * 6)
        let wheelFraction = hue * 6 - wheelIndex
        let low = brightness * (1 - saturation)
        let falling = brightness * (1 - wheelFraction * saturation)
        let rising = brightness * (1 - (1 - wheelFraction) * saturation)
        let segment = Int(wheelIndex).quotientAndRemainder(dividingBy: 6).remainder
        let rgb = rgbValues(
            segment: segment, brightness: brightness, low: low, falling: falling, rising: rising)
        return CGColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }

    private static func rgbValues(
        segment: Int, brightness: CGFloat, low: CGFloat, falling: CGFloat, rising: CGFloat
    ) -> RGBColor {
        switch segment {
        case 0: return RGBColor(red: brightness, green: rising, blue: low)
        case 1: return RGBColor(red: falling, green: brightness, blue: low)
        case 2: return RGBColor(red: low, green: brightness, blue: rising)
        case 3: return RGBColor(red: low, green: falling, blue: brightness)
        case 4: return RGBColor(red: rising, green: low, blue: brightness)
        default: return RGBColor(red: brightness, green: low, blue: falling)
        }
    }

    private static func appendASCII(_ string: String, to data: inout Data) {
        data.append(contentsOf: string.utf8)
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: withUnsafeBytes(of: value.bigEndian) { Array($0) })
    }
}

private struct RGBColor {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
}
