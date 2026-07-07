import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CatalogIconStyler {
    static func styledSVG(_ svg: Data, icon: CatalogIcon) throws -> Data {
        guard let backgroundHex = icon.backgroundHex else { return svg }
        guard
            let text = String(data: svg, encoding: .utf8),
            let insertion = text.range(of: ">"),
            let closing = text.range(of: "</svg>", options: [.backwards, .caseInsensitive])
        else {
            throw MSLError.configuration("icon SVG cannot be decoded")
        }
        let viewBox = try viewBoxValues(in: text)
        let rect = try backgroundRect(viewBox: viewBox, backgroundHex: backgroundHex)
        let group = paddedGroupOpen(viewBox: viewBox)
        let head = String(text[..<insertion.upperBound])
        let body = String(text[insertion.upperBound..<closing.lowerBound])
        let tail = String(text[closing.lowerBound...])
        let styled = head + rect + group + body + "</g>" + tail
        return Data(styled.utf8)
    }

    static func styledPNG(_ png: Data, icon: CatalogIcon) throws -> Data {
        guard let backgroundHex = icon.backgroundHex else { return png }
        let color = try backgroundColor(backgroundHex)
        let image = try decodedImage(png)
        let side = max(image.width, image.height)
        let context = try iconContext(side: side)
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.draw(
            image,
            in: CGRect(
                x: CGFloat(side - image.width) / 2,
                y: CGFloat(side - image.height) / 2,
                width: CGFloat(image.width),
                height: CGFloat(image.height)))
        guard let rendered = context.makeImage() else {
            throw MSLError.io("cannot render styled icon")
        }
        return try pngData(for: rendered)
    }

    private static func decodedImage(_ png: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw MSLError.configuration("icon PNG cannot be decoded")
        }
        return image
    }

    private static func backgroundRect(viewBox: [String], backgroundHex: String) throws -> String {
        _ = try backgroundColor(backgroundHex)
        return
            "<rect x=\"\(viewBox[0])\" y=\"\(viewBox[1])\" width=\"\(viewBox[2])\" "
            + "height=\"\(viewBox[3])\" fill=\"#\(backgroundHex)\"/>"
    }

    private static func paddedGroupOpen(viewBox: [String]) -> String {
        let minX = Double(viewBox[0]) ?? 0.0
        let minY = Double(viewBox[1]) ?? 0.0
        let width = Double(viewBox[2]) ?? 0.0
        let height = Double(viewBox[3]) ?? 0.0
        let scale = 0.78
        let insetX = minX + (width * (1.0 - scale) / 2.0)
        let insetY = minY + (height * (1.0 - scale) / 2.0)
        return "<g transform=\"translate(\(insetX) \(insetY)) scale(\(scale))\">"
    }

    private static func viewBoxValues(in text: String) throws -> [String] {
        let pattern = #"viewBox\s*=\s*"([^"]+)""#
        guard
            let range = text.range(of: pattern, options: .regularExpression),
            let capture = text[range].range(of: #""[^"]+""#, options: .regularExpression)
        else {
            throw MSLError.configuration("icon SVG viewBox missing")
        }
        let values = text[range][capture].dropFirst().dropLast()
            .split { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\t" }
            .map(String.init)
        guard values.count == 4, values.allSatisfy({ Double($0) != nil }) else {
            throw MSLError.configuration("icon SVG viewBox invalid")
        }
        return values
    }

    private static func iconContext(side: Int) throws -> CGContext {
        guard
            let context = CGContext(
                data: nil,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            throw MSLError.io("cannot create icon background")
        }
        return context
    }

    private static func backgroundColor(_ hex: String) throws -> CGColor {
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else {
            throw MSLError.configuration("catalog icon background color invalid")
        }
        let red = CGFloat((value >> 16) & 0xff) / 255.0
        let green = CGFloat((value >> 8) & 0xff) / 255.0
        let blue = CGFloat(value & 0xff) / 255.0
        return CGColor(red: red, green: green, blue: blue, alpha: 1)
    }

    private static func pngData(for image: CGImage) throws -> Data {
        let data = NSMutableData()
        let type = UTType.png.identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else {
            throw MSLError.io("cannot create icon PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw MSLError.io("cannot encode icon PNG")
        }
        return data as Data
    }
}
