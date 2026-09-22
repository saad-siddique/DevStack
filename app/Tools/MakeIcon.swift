// MakeIcon.swift <iconset dir> [--favicon out.png [size]] [--menubar out dir] : renders app/Icon.svg (the single
// icon source) at every size macOS wants in an .iconset, optionally a PNG favicon, and the menu-bar template images
// (MenuBarIcon*.svg at 18 and 36 px). Run with `swift Tools/MakeIcon.swift …`, then `iconutil -c icns`. bin/app does
// this automatically when an SVG or this file changed.
import AppKit

var args = Array(CommandLine.arguments.dropFirst())
let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let svgURL = scriptDir.appendingPathComponent("../Icon.svg").standardizedFileURL
guard let svg = NSImage(contentsOf: svgURL) else { FileHandle.standardError.write("cannot read \(svgURL.path)\n".data(using: .utf8)!); exit(1) }

var menubarDir: String? = nil
if let i = args.firstIndex(of: "--menubar") { menubarDir = args[i + 1]; args.removeSubrange(i ... i + 1) }
var faviconPath: String? = nil
var faviconSize = 64
if let i = args.firstIndex(of: "--favicon") {
	faviconPath = args[i + 1]
	if i + 2 < args.count, let n = Int(args[i + 2]) { faviconSize = n; args.removeSubrange(i ... i + 2) } else { args.removeSubrange(i ... i + 1) }
}
let outDir = args.first ?? "AppIcon.iconset"

func render(_ px: Int, _ image: NSImage = svg) -> Data {
	let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
	                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
	rep.size = NSSize(width: px, height: px)
	NSGraphicsContext.saveGraphicsState()
	let ctx = NSGraphicsContext(bitmapImageRep: rep)!
	NSGraphicsContext.current = ctx
	ctx.imageInterpolation = .high
	image.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .sourceOver, fraction: 1)
	NSGraphicsContext.restoreGraphicsState()
	return rep.representation(using: .png, properties: [:])!
}

if let dir = menubarDir {
	try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
	for name in ["MenuBarIcon", "MenuBarIconAlert"] {
		guard let img = NSImage(contentsOf: scriptDir.appendingPathComponent("../\(name).svg").standardizedFileURL) else { continue }
		try! render(18, img).write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
		try! render(36, img).write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)@2x.png"))
	}
}
if let f = faviconPath {
	try! render(faviconSize).write(to: URL(fileURLWithPath: f))
}
if !outDir.isEmpty {
	try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
	let sizes: [(String, Int)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
	                              ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
	for (name, px) in sizes {
		try! render(px).write(to: URL(fileURLWithPath: outDir).appendingPathComponent("icon_\(name).png"))
	}
}
