// DevStackApp.swift — a menu-bar-only app (LSUIElement). The panel is the MenuBarExtra window; forms and the
// task log open in one ordinary window so they survive the panel closing.
import AppKit
import SwiftUI

/// The same stacked-layers glyph as the app icon, as a template image (alpha only) so the menu bar tints it.
/// Rendered by Tools/MakeIcon.swift into Contents/Resources; falls back to an SF Symbol if the files are missing.
struct MenuBarLabel: View {
	let alert: Bool
	var body: some View {
		if let img = NSImage(named: alert ? "MenuBarIconAlert" : "MenuBarIcon") {
			let _ = { img.isTemplate = true }()
			Image(nsImage: img)
		} else {
			Image(systemName: alert ? "exclamationmark.triangle" : "server.rack")
		}
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
			MenuBarLabel(alert: state.health == .degraded || state.health == .down)
		}
		.menuBarExtraStyle(.window)

		Window("DevStack", id: "modal") {
			ModalView().environmentObject(state)
		}
		.windowResizability(.contentSize)
		.defaultPosition(.center)
	}
}
