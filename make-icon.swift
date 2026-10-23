import AppKit
import Foundation

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let side = CGFloat(pixels)
        let rect = NSRect(x: side * 0.055, y: side * 0.055, width: side * 0.89, height: side * 0.89)
        let shape = NSBezierPath(roundedRect: rect, xRadius: side * 0.20, yRadius: side * 0.20)
        NSGradient(starting: NSColor(red: 0.16, green: 0.33, blue: 0.52, alpha: 1),
                   ending: NSColor(red: 0.06, green: 0.17, blue: 0.30, alpha: 1))!.draw(in: shape, angle: -90)
        let configuration = NSImage.SymbolConfiguration(pointSize: side * 0.52, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        let symbol = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: nil)!.withSymbolConfiguration(configuration)!
        let ratio = symbol.size.height / symbol.size.width
        let width = side * 0.63
        symbol.draw(in: NSRect(x: (side - width) / 2, y: (side - width * ratio) / 2, width: width, height: width * ratio))
        NSColor(red: 0.35, green: 0.89, blue: 0.68, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: side * 0.67, y: side * 0.66, width: side * 0.16, height: side * 0.16)).fill()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let data = bitmap.representation(using: .png, properties: [:])!
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to: folder.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}

// ICNS is a sequence of typed image elements, each with a big-endian length.
func lengthData(_ value: Int) -> Data {
    var length = UInt32(value).bigEndian
    return withUnsafeBytes(of: &length) { Data($0) }
}
var elements = Data()
for (type, file) in [("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"),
                     ("icp6", "icon_32x32@2x.png"), ("ic07", "icon_128x128.png"),
                     ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
                     ("ic10", "icon_512x512@2x.png"), ("ic11", "icon_16x16@2x.png"),
                     ("ic12", "icon_32x32@2x.png"), ("ic13", "icon_128x128@2x.png"),
                     ("ic14", "icon_256x256@2x.png")] {
    let png = try Data(contentsOf: folder.appendingPathComponent(file))
    elements.append(Data(type.utf8))
    elements.append(lengthData(png.count + 8))
    elements.append(png)
}
var icon = Data("icns".utf8)
icon.append(lengthData(elements.count + 8))
icon.append(elements)
try icon.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
