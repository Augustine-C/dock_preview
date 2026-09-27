import AppKit

// Finder uses a fixed 720 × 480 canvas; icon positions are set in dmg-layout.py.
let size = NSSize(width: 720, height: 480)
let image = NSImage(size: size)
image.lockFocus()
NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.99, alpha: 1).setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

func label(_ text: String, y: CGFloat, size: CGFloat, bold: Bool = false) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    (text as NSString).draw(in: NSRect(x: 20, y: y, width: 680, height: size + 12),
                           withAttributes: [.font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
                                            .foregroundColor: NSColor(calibratedWhite: 0.2, alpha: 1),
                                            .paragraphStyle: paragraph])
}
label("Dock Preview", y: 410, size: 30, bold: true)
label("Drag to Applications to install · 拖到应用程序以安装", y: 376, size: 16)

for x: CGFloat in [80, 440] {
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: 210, width: 200, height: 150), xRadius: 20, yRadius: 20).fill()
}
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 306, y: 290))
arrow.line(to: NSPoint(x: 410, y: 290))
arrow.move(to: NSPoint(x: 391, y: 308))
arrow.line(to: NSPoint(x: 410, y: 290))
arrow.line(to: NSPoint(x: 391, y: 272))
arrow.lineWidth = 6
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
NSColor(calibratedRed: 0.24, green: 0.39, blue: 0.87, alpha: 1).setStroke()
arrow.stroke()

label("Installation guides · 安装指南", y: 167, size: 15, bold: true)
label("First launch & permissions: read a guide · 首次打开与授权：请阅读指南", y: 14, size: 12)
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
