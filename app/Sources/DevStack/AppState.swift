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
	@Published private(set) var update: UpdateInfo?
	@Published private(set) var checkingUpdates = false

	let sampler = UsageSampler()
	let installed = Devstack.isInstalled
	/// Snapshot mode: fixture data on screen, never replaced by a real status read.
	private var frozen = false
	/// Set by the panel (it owns the SwiftUI openWindow action); jobs started from anywhere use it.
	var showModalWindow: (() -> Void)?
	private var loop: Task<Void, Never>?

	init() {
		if !installed { errorMessage = Devstack.Failure.notInstalled.localizedDescription }
		Task { await refresh() }
		schedule()
		scheduleUpdateChecks()
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
		guard installed, !isRefreshing, !frozen else { return }
		isRefreshing = true
		defer { isRefreshing = false }
		do {
			let fresh = try await Devstack.runJSON(StackStatus.self, ["status", "--json"])
			if frozen { return }
			status = fresh
			lastUpdated = Date()
			errorMessage = nil
		} catch {
			if frozen { return }
			errorMessage = error.localizedDescription
		}
	}

	func setUpdate(_ info: UpdateInfo?) { update = info }   // snapshot fixtures only

	func freeze(with fixture: StackStatus) {
		frozen = true
		status = fixture
		lastUpdated = Date()
		errorMessage = nil
	}

	// MARK: updates (a fetch every six hours; applying is always a click)

	private var updateLoop: Task<Void, Never>?

	private func scheduleUpdateChecks() {
		guard installed else { return }
		updateLoop = Task { [weak self] in
			try? await Task.sleep(for: .seconds(20))
			while !Task.isCancelled {
				await self?.checkForUpdates()
				try? await Task.sleep(for: .seconds(6 * 3600))
			}
		}
	}

	func checkForUpdates() async {
		guard installed, !frozen, !checkingUpdates else { return }
		checkingUpdates = true
		defer { checkingUpdates = false }
		// Silent on failure: no network or no upstream is not worth a red line in the panel.
		update = try? await Devstack.runJSON(UpdateInfo.self, ["update", "--check", "--json"])
	}

	func runUpdate() { runJob(title: "Update DevStack", ["update", "--json"]) }

	/// Homebrew upgrades of the stack. --all applies minor/major releases too; the nightly agent only does patches.
	func runUpgrade(all: Bool) { runJob(title: all ? "Upgrade stack (everything outdated)" : "Upgrade stack (patch releases)", ["upgrade", all ? "--all" : "--auto", "--json"]) }
	func checkUpgrades() async { await quick("upgrade-check", ["upgrade", "--check", "--json"]) }
	/// The developer's choice for the 03:30 run: report only (off) or apply patch releases unattended.
	func setNightlyUpgrades(_ on: Bool) async { await quick("upgrade-auto", ["upgrade", "--set-auto", on ? "patch" : "off", "--json"]) }

	/// The app cannot replace itself while running: hand the rebuild to a detached `devstack app install`, which
	/// builds, installs into /Applications and relaunches, then quit.
	func restartAfterUpdate() {
		let p = Process()
		p.executableURL = URL(fileURLWithPath: "/bin/bash")
		let log = NSHomeDirectory() + "/Library/Logs/DevStack/app-install.log"
		p.arguments = ["-c", "sleep 1; PATH=/opt/homebrew/bin:/usr/bin:/bin /opt/homebrew/bin/devstack app install > '\(log)' 2>&1"]
		try? FileManager.default.createDirectory(atPath: (log as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
		do { try p.run() } catch { errorMessage = "Could not start the rebuild: \(error.localizedDescription)"; return }
		NSApp.terminate(nil)
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

	func createSite(name: String, php: String, empty: Bool, adminUser: String, adminPassword: String, adminEmail: String) {
		var args = ["new", name, "--php", php, "--json"]
		if empty { args.append("--empty") } else { args += ["--admin-user", adminUser, "--admin-password", adminPassword, "--admin-email", adminEmail] }
		runJob(title: "New site \(name)", args)
	}

	/// One-time login link (60 s) minted by `devstack login`; the browser lands in wp-admin signed in.
	func login(siteNamed name: String) async {
		busy.insert(name)
		defer { busy.remove(name) }
		let r = await Devstack.run(["login", name, "--print"])
		let url = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
		if r.status == 0, url.hasPrefix("http") { open(url) } else { errorMessage = r.lastErrorLine }
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
			if args.first == "update", status == 0 { update = nil }
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
