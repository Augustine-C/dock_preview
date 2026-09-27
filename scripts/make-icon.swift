import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for multiplier in [1, 2] {
        let pixels = size * multiplier
        let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let scale = CGFloat(pixels) / 1024
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(CGColor(red: 0.12, green: 0.38, blue: 0.88, alpha: 1))
        context.addPath(CGPath(roundedRect: CGRect(x: 40, y: 40, width: 944, height: 944), cornerWidth: 210, cornerHeight: 210, transform: nil))
        context.fillPath()
        for (rect, alpha) in [(CGRect(x: 180, y: 410, width: 550, height: 370), CGFloat(0.55)),
                              (CGRect(x: 300, y: 240, width: 550, height: 370), CGFloat(1))] {
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 38, cornerHeight: 38, transform: nil))
            context.fillPath()
            context.setFillColor(CGColor(red: 0.12, green: 0.38, blue: 0.88, alpha: alpha))
            context.addPath(CGPath(roundedRect: CGRect(x: rect.minX + 25, y: rect.minY + 25, width: rect.width - 50, height: rect.height - 100), cornerWidth: 16, cornerHeight: 16, transform: nil))
            context.fillPath()
            for index in 0..<3 {
                context.fillEllipse(in: CGRect(x: rect.minX + 30 + CGFloat(index) * 36, y: rect.maxY - 51, width: 19, height: 19))
            }
        }
        let suffix = multiplier == 2 ? "@2x" : ""
        let output = folder.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
    }
}
// ICNS embeds PNG payloads; encode the container directly to keep the build
// independent of iconutil's system image conversion service.
func lengthBytes(_ value: Int) -> Data {
    var bigEndian = UInt32(value).bigEndian
    return withUnsafeBytes(of: &bigEndian) { Data($0) }
}
var chunks = Data()
for (type, filename) in [
    ("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"), ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"), ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"), ("ic11", "icon_16x16@2x.png"),
    ("ic12", "icon_32x32@2x.png"), ("ic13", "icon_128x128@2x.png"), ("ic14", "icon_256x256@2x.png")
] {
    let png = try Data(contentsOf: folder.appendingPathComponent(filename))
    chunks.append(Data(type.utf8)); chunks.append(lengthBytes(png.count + 8)); chunks.append(png)
}
var container = Data("icns".utf8)
container.append(lengthBytes(chunks.count + 8)); container.append(chunks)
try container.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
