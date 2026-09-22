// DevStackApp.swift — a menu-bar-only app (LSUIElement). The panel is the MenuBarExtra window; forms and the
// task log open in one ordinary window so they survive the panel closing.
import AppKit
import SwiftUI

/// The same stacked-layers glyph as the app icon, as a template image (alpha only) so the menu bar tints it.
/// Rendered by Tools/MakeIcon.swift into Contents/Resources; falls back to an SF Symbol if the files are missing.
struct MenuBarLabel: View {
	let alert: Bool
	let samples: [Double]?      // CPU % history when the menu-bar graph is on

	var body: some View {
		if let base = NSImage(named: alert ? "MenuBarIconAlert" : "MenuBarIcon") {
			let _ = { base.isTemplate = true }()
			if let samples, samples.count > 1 {
				Image(nsImage: Self.withSparkline(base, samples))
			} else {
				Image(nsImage: base)
			}
		} else {
			Image(systemName: alert ? "exclamationmark.triangle" : "server.rack")
		}
	}

	/// Glyph + a 36×14 pt sparkline of the last samples, alpha only so the menu bar tints it like any template.
	static func withSparkline(_ glyph: NSImage, _ samples: [Double]) -> NSImage {
		let w: CGFloat = 18 + 4 + 36, h: CGFloat = 18
		let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
			glyph.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
			let pts = Array(samples.suffix(36))
			let maxV = max(20, pts.max() ?? 0)
			let x0: CGFloat = 22, gw: CGFloat = 36, gh: CGFloat = 12, y0: CGFloat = 3
			let path = NSBezierPath()
			for (i, v) in pts.enumerated() {
				let x = x0 + gw * CGFloat(i) / CGFloat(max(1, pts.count - 1))
				let y = y0 + gh * CGFloat(min(1, v / maxV))
				i == 0 ? path.move(to: NSPoint(x: x, y: y)) : path.line(to: NSPoint(x: x, y: y))
			}
			NSColor.black.withAlphaComponent(0.85).setStroke()
			path.lineWidth = 1.5
			path.lineJoinStyle = .round
			path.stroke()
			let base = NSBezierPath()
			base.move(to: NSPoint(x: x0, y: y0 - 1.5)); base.line(to: NSPoint(x: x0 + gw, y: y0 - 1.5))
			NSColor.black.withAlphaComponent(0.25).setStroke()
			base.lineWidth = 1
			base.stroke()
			return true
		}
		img.isTemplate = true
		return img
	}
}

@main
struct DevStackApp: App {
	@StateObject private var state = AppState.shared

	init() { Snapshot.handleLaunchArguments(state: AppState.shared) }

	var body: some Scene {
		MenuBarExtra {
			PanelView().environmentObject(state)
		} label: {
			MenuBarLabel(alert: state.health == .degraded || state.health == .down, samples: state.menuBarGraph ? state.sampler.samples.map(\.cpu) : nil)
		}
		.menuBarExtraStyle(.window)
	}
}
