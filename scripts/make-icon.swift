import AppKit
let folder = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
func icon(_ size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let c = NSGraphicsContext.current!.cgContext; c.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    c.setFillColor(NSColor(calibratedRed: 0.06, green: 0.10, blue: 0.16, alpha: 1).cgColor)
    c.addPath(CGPath(roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896), cornerWidth: 210, cornerHeight: 210, transform: nil)); c.fillPath()
    c.setStrokeColor(NSColor(calibratedRed: 0.40, green: 0.91, blue: 0.77, alpha: 1).cgColor); c.setLineWidth(40)
    c.addPath(CGPath(roundedRect: CGRect(x: 198, y: 307, width: 628, height: 433), cornerWidth: 48, cornerHeight: 48, transform: nil)); c.strokePath()
    c.move(to: CGPoint(x: 410, y: 232)); c.addLine(to: CGPoint(x: 612, y: 232)); c.strokePath()
    c.setFillColor(NSColor(calibratedRed: 0.40, green: 0.91, blue: 0.77, alpha: 1).cgColor)
    c.fillEllipse(in: CGRect(x: 554, y: 222, width: 302, height: 302))
    c.setFillColor(NSColor(calibratedRed: 0.05, green: 0.17, blue: 0.20, alpha: 1).cgColor)
    c.fillEllipse(in: CGRect(x: 654, y: 375, width: 100, height: 100))
    c.addPath(CGPath(roundedRect: CGRect(x: 614, y: 272, width: 181, height: 95), cornerWidth: 46, cornerHeight: 46, transform: nil)); c.fillPath()
    c.setFillColor(NSColor(calibratedRed: 1, green: 0.34, blue: 0.31, alpha: 1).cgColor)
    c.fillEllipse(in: CGRect(x: 255, y: 625, width: 62, height: 62))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for base in [16, 32, 128, 256, 512] {
    try icon(base).write(to: URL(fileURLWithPath: "\(folder)/icon_\(base)x\(base).png"))
    try icon(base * 2).write(to: URL(fileURLWithPath: "\(folder)/icon_\(base)x\(base)@2x.png"))
}
