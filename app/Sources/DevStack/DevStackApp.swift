// DevStackApp.swift — a menu-bar-only app (LSUIElement). The panel is the MenuBarExtra window; forms and the
// task log open in one ordinary window so they survive the panel closing.
import SwiftUI

@main
struct DevStackApp: App {
	@StateObject private var state = AppState.shared

	init() { Snapshot.handleLaunchArguments(state: AppState.shared) }

	var body: some Scene {
		MenuBarExtra {
			PanelView().environmentObject(state)
		} label: {
			Image(systemName: state.menuBarSymbol)
		}
		.menuBarExtraStyle(.window)

		Window("DevStack", id: "modal") {
			ModalView().environmentObject(state)
		}
		.windowResizability(.contentSize)
		.defaultPosition(.center)
	}
}
