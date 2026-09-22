// Snapshot.swift — `DevStack --snapshot <dir>` renders the panel and each form into PNGs and quits.
// Used by `devstack app snapshot` for the README and for checking the UI without clicking through the menu bar.
// It captures the app's own windows, which needs no screen-recording permission.
import AppKit
import SwiftUI

@MainActor
enum Snapshot {
	static func handleLaunchArguments(state: AppState) {
		let args = CommandLine.arguments
		guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
		let dir = args[i + 1]
		Task { await run(state: state, dir: dir) }
	}

	private static func run(state: AppState, dir: String) async {
		for _ in 0 ..< 80 where state.status == nil { try? await Task.sleep(for: .milliseconds(250)) }
		try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		state.sampler.start()
		try? await Task.sleep(for: .seconds(7))          // a few load samples so the chart has a line
		await capture(PanelView().environmentObject(state), "panel", dir)
		state.modal = .newSite
		await capture(ModalView().environmentObject(state), "new-site", dir)
		state.modal = .importSite
		await capture(ModalView().environmentObject(state), "import", dir)
		if let site = state.status?.userSites.first(where: { !$0.isProtected }) {
			state.modal = .remove(site)
			await capture(ModalView().environmentObject(state), "remove", dir)
		}
		state.task = TaskLog(title: "Back up cleantest", command: "devstack backup cleantest --json",
		                     lines: ["12:28:36 === site-backup cleantest -> ~/Backups/local-devstack/cleantest/20260922-122836",
		                             "12:28:37 db: dumping wp_cleantest_db (43 tables)", "12:28:37 db: 332K compressed",
		                             "12:28:39 files: cloned 10546 files", "12:28:39 done: ~/Backups/local-devstack/cleantest/20260922-122836 (264M on disk)"]
		                        .map { Devstack.Line(isError: true, text: $0) },
		                     running: false, exitStatus: 0,
		                     result: JobResult(name: "cleantest", url: nil, path: NSHomeDirectory() + "/Backups/local-devstack/cleantest/20260922-122836", adminUser: nil, adminPassword: nil, ok: true))
		state.modal = .task
		await capture(ModalView().environmentObject(state), "task", dir)
		print("snapshots written to \(dir)")
		NSApp.terminate(nil)
	}

	private static func capture<V: View>(_ view: V, _ name: String, _ dir: String) async {
		let host = NSHostingController(rootView: view)
		let window = NSWindow(contentViewController: host)
		window.styleMask = [.titled, .fullSizeContentView]
		window.titlebarAppearsTransparent = true
		window.titleVisibility = .hidden
		window.isMovableByWindowBackground = false
		window.setContentSize(host.view.fittingSize)
		window.center()
		window.orderFrontRegardless()                    // on screen, but never key: the user's typing stays where it was
		try? await Task.sleep(for: .milliseconds(1200))
		window.displayIfNeeded()
		let id = CGWindowID(window.windowNumber)
		if let img = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]) {
			let rep = NSBitmapImageRep(cgImage: img)
			try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
		}
		window.orderOut(nil)
	}
}
