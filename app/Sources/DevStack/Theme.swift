// Theme.swift — one layout, two palettes chosen by the system appearance: "Glass" in light (translucent cards on a
// cool gradient, teal accent from the icon) and "Console" in dark (graphite, glowing green LEDs, light-teal accent).
import SwiftUI

struct Theme {
	let dark: Bool
	init(_ scheme: ColorScheme) { dark = scheme == .dark }

	var background: LinearGradient {
		dark ? LinearGradient(colors: [Color(hex: 0x14181D), Color(hex: 0x10141A)], startPoint: .top, endPoint: .bottom)
		     : LinearGradient(colors: [Color(hex: 0xE9EEF2), Color(hex: 0xEEF1F4)], startPoint: .top, endPoint: .bottom)
	}
	var hero: LinearGradient {
		dark ? LinearGradient(colors: [Color(hex: 0x0B2A3F), Color(hex: 0x0F4F5A), Color(hex: 0x0B1420)], startPoint: .topLeading, endPoint: .bottomTrailing)
		     : LinearGradient(colors: [Color(hex: 0x1F4A72), Color(hex: 0x0F6473), Color(hex: 0x0A2C44)], startPoint: .topLeading, endPoint: .bottomTrailing)
	}
	var card: Color { dark ? Color(hex: 0x1A1F26) : Color.white.opacity(0.84) }
	var cardBorder: Color { dark ? Color(hex: 0x262D36) : Color.white.opacity(0.95) }
	var cardShadow: Color { dark ? Color.black.opacity(0.40) : Color(hex: 0x141E28).opacity(0.10) }
	var accent: Color { dark ? Color(hex: 0x7FD1CF) : Color(hex: 0x0F6473) }
	var text: Color { dark ? Color(hex: 0xD7DDE4) : Color(hex: 0x1C2733) }
	var muted: Color { dark ? Color(hex: 0x7F8B98) : Color(hex: 0x6B7683) }
	var faint: Color { dark ? Color(hex: 0x56616D) : Color(hex: 0x8A96A3) }
	var divider: Color { dark ? Color(hex: 0x232B34) : Color(hex: 0xEEF1F4) }
	var tile: Color { dark ? Color(hex: 0x1F3036) : Color(hex: 0xE6F4F3) }
	var tileText: Color { dark ? Color(hex: 0x7FD1CF) : Color(hex: 0x0F6473) }
	var badTile: Color { dark ? Color(hex: 0x3B1F1F) : Color(hex: 0xFDE8E6) }
	var badTileText: Color { dark ? Color(hex: 0xFF6B5C) : Color(hex: 0xC93A2B) }
	var warnTile: Color { dark ? Color(hex: 0x3A2E14) : Color(hex: 0xFFF1D6) }
	var warnTileText: Color { dark ? Color(hex: 0xE0A83A) : Color(hex: 0xA66A00) }
	var ok: Color { dark ? Color(hex: 0x3DDC84) : Color(hex: 0x178A4E) }
	var bad: Color { dark ? Color(hex: 0xFF6B5C) : Color(hex: 0xB3261E) }
	var warn: Color { dark ? Color(hex: 0xE0A83A) : Color(hex: 0xA66A00) }
	var off: Color { dark ? Color(hex: 0x4A5560) : Color(hex: 0xB8C2CC) }
	var glow: Bool { dark }
	var heroText: Color { .white }
	var heroMuted: Color { Color.white.opacity(0.78) }
}

extension Color {
	init(hex: UInt32) {
		self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: 1)
	}
}

/// The card surface everything sits on.
struct Card<Content: View>: View {
	@Environment(\.colorScheme) private var scheme
	var padding: CGFloat = 0
	@ViewBuilder var content: Content
	var body: some View {
		let t = Theme(scheme)
		content
			.padding(padding)
			.background(t.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
			.overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(t.cardBorder, lineWidth: 1))
			.shadow(color: t.cardShadow, radius: 10, y: 4)
	}
}

/// Notice lines (update, upgrades, share, runaway, reports, error) share this surface: a card with a tinted edge.
struct Notice: ViewModifier {
	@Environment(\.colorScheme) private var scheme
	let tint: Color
	func body(content: Content) -> some View {
		let t = Theme(scheme)
		content
			.padding(.horizontal, 12).padding(.vertical, 8)
			.background(t.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
			.overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 3).padding(.vertical, 8).padding(.leading, 4) }
			.overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(t.cardBorder, lineWidth: 1))
			.shadow(color: t.cardShadow, radius: 8, y: 3)
	}
}
extension View { func notice(_ tint: Color) -> some View { modifier(Notice(tint: tint)) } }

/// The letter tile that leads a site row (or an icon for a special state).
struct Tile: View {
	@Environment(\.colorScheme) private var scheme
	enum Kind { case normal, bad, warn }
	let text: String
	var symbol: String? = nil
	var kind: Kind = .normal
	var body: some View {
		let t = Theme(scheme)
		let bg = kind == .bad ? t.badTile : (kind == .warn ? t.warnTile : t.tile)
		let fg = kind == .bad ? t.badTileText : (kind == .warn ? t.warnTileText : t.tileText)
		ZStack {
			RoundedRectangle(cornerRadius: 8, style: .continuous).fill(bg)
			if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .bold)) } else { Text(text).font(.system(size: 12, weight: .bold, design: .rounded)) }
		}
		.foregroundStyle(fg)
		.frame(width: 26, height: 26)
	}
}
