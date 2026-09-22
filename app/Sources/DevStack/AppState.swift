// AppState.swift — one observable object: the last `devstack status`, refresh cadence, and every action.
// Cadence is deliberately lean: one status read per minute while the panel is open, one per five minutes while
// closed (for the menu-bar icon), CPU samples only while the panel is open.
import AppKit
import ServiceManagement
import SwiftUI

struct TaskLog {
	var title = ""
	var command = ""
	var lines: [Devstack.Line] = []
	var running = false
	var exitStatus: Int32?
	var result: JobResult?

	var succeeded: Bool { exitStatus == 0 }

	mutating func finish(_ status: Int32) {
		running = false
		exitStatus = status
		// site-new/import/backup print one JSON object on stdout at the end.
		if let json = lines.last(where: { !$0.isError && $0.text.hasPrefix("{") })?.text {
			result = try? Devstack.decoder.decode(JobResult.self, from: Data(json.utf8))
		}
		if result == nil, let objectStart = lines.lastIndex(where: { !$0.isError && $0.text == "{" }) {
			let json = lines[objectStart...].filter { !$0.isError }.map(\.text).joined(separator: "\n")
			result = try? Devstack.decoder.decode(JobResult.self, from: Data(json.utf8))
		}
	}
}

@MainActor
final class AppState: ObservableObject {
	static let shared = AppState()

	enum Modal: Equatable {
		case newSite
		case importSite
		case remove(Site)
		case task
	}

	@Published private(set) var status: StackStatus?
	@Published private(set) var lastUpdated: Date?
	@Published private(set) var isRefreshing = false
	@Published var errorMessage: String?
	@Published private(set) var busy: Set<String> = []
	@Published var modal: Modal?
	@Published var task = TaskLog()
	@Published private(set) var panelOpen = false

	let sampler = UsageSampler()
	let installed = Devstack.isInstalled
	/// Set by the panel (it owns the SwiftUI openWindow action); jobs started from anywhere use it.
	var showModalWindow: (() -> Void)?
	private var loop: Task<Void, Never>?

	init() {
		if !installed { errorMessage = Devstack.Failure.notInstalled.localizedDescription }
		Task { await refresh() }
		schedule()
	}

	var health: Health {
		guard installed, errorMessage == nil || status != nil else { return .unknown }
		return status?.health ?? .unknown
	}

	var menuBarSymbol: String {
		if task.running { return "arrow.triangle.2.circlepath" }
		switch health {
		case .ok: return "server.rack"
		case .degraded: return "exclamationmark.triangle"
		case .down: return "xmark.octagon"
		case .unknown: return "questionmark.square.dashed"
		}
	}

	// MARK: cadence

	private func schedule() {
		loop?.cancel()
		loop = Task { [weak self] in
			while !Task.isCancelled {
				let seconds = self?.panelOpen == true ? 60 : 300
				try? await Task.sleep(for: .seconds(seconds))
				if Task.isCancelled { return }
				await self?.refresh()
			}
		}
	}

	func panelDidAppear() {
		panelOpen = true
		sampler.start()
		if let t = lastUpdated, Date().timeIntervalSince(t) < 10 { } else { Task { await refresh() } }
		schedule()
	}

	func panelDidDisappear() {
		panelOpen = false
		sampler.stop()
		schedule()
	}

	func refresh() async {
		guard installed, !isRefreshing else { return }
		isRefreshing = true
		defer { isRefreshing = false }
		do {
			status = try await Devstack.runJSON(StackStatus.self, ["status", "--json"])
			lastUpdated = Date()
			errorMessage = nil
		} catch {
			errorMessage = error.localizedDescription
		}
	}

	// MARK: quick actions (a few seconds; the row shows a spinner)

	func toggle(_ s: Service) async { await quick(s.name, ["service", s.name, s.isRunning ? "stop" : "start"]) }
	func restart(_ s: Service) async { await quick(s.name, ["service", s.name, "restart"]) }
	func toggleXdebug(_ p: PhpVersion) async { await quick("php@\(p.version)", ["xdebug", p.xdebug ? "off" : "on", "--php", p.version]) }
	func toggleFpm(_ p: PhpVersion) async { await quick("php@\(p.version)", ["service", "php@\(p.version)", p.fpmRunning ? "stop" : "start"]) }

	func isBusy(_ key: String) -> Bool { busy.contains(key) }

	private func quick(_ key: String, _ args: [String]) async {
		busy.insert(key)
		defer { busy.remove(key) }
		let r = await Devstack.run(args)
		if r.status != 0 { errorMessage = r.lastErrorLine }
		await refresh()
	}

	// MARK: jobs (seconds to minutes; streamed into the task window)

	func createSite(name: String, php: String, empty: Bool) {
		var args = ["new", name, "--php", php, "--json"]
		if empty { args.append("--empty") }
		runJob(title: "New site \(name)", args)
	}

	func importSite(name: String, source: String, sql: String?, php: String?) {
		var args = ["import", name, source, "--json"]
		if let sql, !sql.isEmpty { args += ["--sql", sql] }
		if let php, !php.isEmpty { args += ["--php", php] }
		runJob(title: "Import \(name)", args)
	}

	func backup(_ site: Site) { runJob(title: "Back up \(site.name)", ["backup", site.name, "--json"]) }

	func remove(_ site: Site, backupFirst: Bool) {
		var args = ["remove", site.name, "--yes"]
		if backupFirst { args.append("--backup") }
		runJob(title: "Remove \(site.name)", args)
	}

	private func runJob(title: String, _ args: [String]) {
		guard !task.running else { errorMessage = "Another task is still running."; return }
		task = TaskLog(title: title, command: "devstack " + args.joined(separator: " "), running: true)
		modal = .task
		showModalWindow?()
		Task {
			let status = await Devstack.stream(args) { [weak self] line in
				Task { @MainActor in self?.task.lines.append(line) }
			}
			task.finish(status)
			await refresh()
		}
	}

	// MARK: open things

	func open(_ url: String) {
		guard let u = URL(string: url) else { return }
		NSWorkspace.shared.open(u)
	}

	func openFolder(_ path: String) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }

	func copy(_ text: String) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(text, forType: .string)
	}

	func openRepo() {
		Task {
			let r = await Devstack.run(["path"])
			let p = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
			if r.status == 0, !p.isEmpty { openFolder(p) }
		}
	}

	// MARK: login item

	var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

	func setLaunchAtLogin(_ on: Bool) {
		do {
			if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
		} catch {
			errorMessage = "Start at login: \(error.localizedDescription)"
		}
		objectWillChange.send()
	}
}
