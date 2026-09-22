// MakeIcon.swift <iconset dir> : renders the DevStack app icon (a stack of three server bars) at every size
// macOS wants in an .iconset. Run with `swift Tools/MakeIcon.swift out.iconset`, then `iconutil -c icns`.
import AppKit

let outDir = CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
	let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
	                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
	rep.size = NSSize(width: px, height: px)
	NSGraphicsContext.saveGraphicsState()
	NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
	let s = CGFloat(px)
	let inset = s * 0.09                       // Apple's icon grid leaves ~9% air around the tile
	let tile = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
	let tilePath = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
	NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.62, blue: 0.52, alpha: 1),
	           ending: NSColor(calibratedRed: 0.05, green: 0.27, blue: 0.30, alpha: 1))!.draw(in: tilePath, angle: -70)
	// Three rack bars with one lit LED each.
	let barW = tile.width * 0.58, barH = tile.height * 0.135, gap = tile.height * 0.055
	var y = tile.midY - (barH * 3 + gap * 2) / 2
	for _ in 0 ..< 3 {
		let bar = NSRect(x: tile.midX - barW / 2, y: y, width: barW, height: barH)
		NSColor(calibratedWhite: 1, alpha: 0.94).setFill()
		NSBezierPath(roundedRect: bar, xRadius: barH * 0.28, yRadius: barH * 0.28).fill()
		let led = NSRect(x: bar.maxX - barH * 0.72, y: bar.midY - barH * 0.17, width: barH * 0.34, height: barH * 0.34)
		NSColor(calibratedRed: 0.20, green: 0.85, blue: 0.45, alpha: 1).setFill()
		NSBezierPath(ovalIn: led).fill()
		y += barH + gap
	}
	NSGraphicsContext.restoreGraphicsState()
	return rep.representation(using: .png, properties: [:])!
}

let sizes: [(String, Int)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                              ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
for (name, px) in sizes {
	try! render(px).write(to: URL(fileURLWithPath: outDir).appendingPathComponent("icon_\(name).png"))
}
