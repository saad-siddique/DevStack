// AppState.swift — one observable object: the last `devstack status`, refresh cadence, and every action.
// Cadence is deliberately lean: one status read per minute while the panel is open, one per five minutes while
// closed (for the menu-bar icon), CPU samples only while the panel is open.
import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

struct TaskLog: Identifiable {
	let id = UUID()
	var title = ""
	var command = ""
	var lines: [Devstack.Line] = []
	var running = false
	var exitStatus: Int32?
	var result: JobResult?
	let startedAt = Date()

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
		case clone(Site)
		case backups(String?)      // optional site filter
		case panel                 // the menu-bar panel in a window (hotkey fallback)
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
	@Published private(set) var reports: Reports?
	@Published var dismissedReportIDs: Set<String> = []
	@Published private(set) var backups: [BackupEntry] = []
	@Published private(set) var loadingBackups = false
	@Published private(set) var history: [TaskLog] = []
	@Published var notificationsEnabled: Bool = UserDefaults.standard.object(forKey: "notifications") as? Bool ?? true {
		didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "notifications") }
	}

	let sampler = UsageSampler()
	let installed = Devstack.isInstalled
	/// Snapshot mode: fixture data on screen, never replaced by a real status read.
	private var frozen = false
	/// The one ordinary window (forms, backups, task log, hotkey panel), owned here so anything can open it any time.
	private var modalWindowStore: NSWindow?
	private var modalWindow: NSWindow {
		if let w = modalWindowStore { return w }
		let host = NSHostingController(rootView: ModalView().environmentObject(self))
		host.sizingOptions = [.preferredContentSize]
		let w = NSWindow(contentViewController: host)
		w.styleMask = [.titled, .closable, .miniaturizable]
		w.isReleasedWhenClosed = false
		w.title = "DevStack"
		w.center()
		modalWindowStore = w
		return w
	}

	func presentModal() {
		let w = modalWindow
		w.title = modalTitle
		if !w.isVisible { w.center() }
		w.makeKeyAndOrderFront(nil)
		NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
	}

	func closeModal() { modalWindowStore?.orderOut(nil) }

	private var modalTitle: String {
		switch modal {
		case .newSite: return "New site"
		case .importSite: return "Import site"
		case .remove(let s): return "Archive \(s.name)"
		case .clone(let s): return "Duplicate \(s.name)"
		case .backups: return "Backups"
		case .panel: return "DevStack"
		case .task: return task.title.isEmpty ? "Task" : task.title
		case nil: return "DevStack"
		}
	}
	private var loop: Task<Void, Never>?

	private let notifier = Notifier()
	private var seenReportIDs: Set<String>?          // nil until the first read: existing reports are not news
	private var lastHealth: Health = .unknown
	private var lastUpgradeRunAt: String??            // nil until first read
	private var notifiedUpdateHead: String?
	private var lastWatchdogActionID: String??        // nil until first read
	private var hotKey: HotKey?

	init() {
		if !installed { errorMessage = Devstack.Failure.notInstalled.localizedDescription }
		sampler.start(interval: UserDefaults.standard.bool(forKey: "menubar.graph") ? 15 : 60)
		Task { await refresh() }
		schedule()
		scheduleUpdateChecks()
		hotKey = HotKey { [weak self] in self?.togglePanel() }
	}

	private func notify(_ title: String, _ body: String) {
		guard notificationsEnabled else { return }
		notifier.post(title: title, body: body)
	}

	/// ⌃⌥D: SwiftUI gives no way to open a MenuBarExtra from code (its popover is not even in NSApp.windows), so the
	/// hotkey shows the same panel in a window; pressing again while it is up hides it.
	func togglePanel() {
		if let w = modalWindowStore, w.isVisible, modal == .panel { w.orderOut(nil); return }
		modal = .panel
		presentModal()
	}


	var runaways: [UsageSampler.Runaway] { sampler.runaways }

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
		sampler.start(interval: 3)
		if let t = lastUpdated, Date().timeIntervalSince(t) < 10 { } else { Task { await refresh() } }
		schedule()
	}

	func panelDidDisappear() {
		panelOpen = false
		sampler.start(interval: menuBarGraph ? 15 : 60)
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
		reports = try? await Devstack.runJSON(Reports.self, ["logs", "crashes", "--hours", "24", "--json"])
		noticeChanges()
	}

	/// Turn state changes into macOS notifications: health dropping, a new crash or resource report, an overnight
	/// upgrade, an update becoming available. Nothing fires on the first read after launch.
	private func noticeChanges() {
		if let st = status {
			let h = st.health
			if lastHealth == .ok, h == .down || h == .degraded {
				let down = st.coreServices.filter { !$0.isRunning }.map(\.name)
				notify(h == .down ? "DevStack: a core service is down" : "DevStack: stack degraded",
				       down.isEmpty ? "launchd reports an error. Open DevStack for details." : "\(down.joined(separator: ", ")) not running.")
			}
			lastHealth = h
			let runAt = st.upgrades?.lastRun?.at
			if let previous = lastUpgradeRunAt, previous != runAt, let run = st.upgrades?.lastRun {
				let up = (run.upgraded ?? []).map { "\($0.name) \($0.from) → \($0.to)" }
				let failed = (run.failed ?? []).map(\.name)
				if !up.isEmpty || !failed.isEmpty {
					notify(failed.isEmpty ? "DevStack upgraded the stack" : "DevStack: stack upgrade had failures",
					       (up.isEmpty ? "" : up.joined(separator: ", ")) + (failed.isEmpty ? "" : " Failed: \(failed.joined(separator: ", "))"))
				}
			}
			lastUpgradeRunAt = .some(runAt)
			// Watchdog: a new action since last time means nginx or dnsmasq was brought back.
			let lastAction = st.watchdog?.actions?.last
			if let previous = lastWatchdogActionID, previous != lastAction?.id, let a = lastAction {
				notify("DevStack watchdog: \(a.service) \(a.result ?? "restarted")", "It was \(a.statusBefore ?? "down") with no process running.")
			}
			lastWatchdogActionID = .some(lastAction?.id)
		}
		if let r = reports {
			let ids = Set((r.reports ?? []).map(\.id))
			if let seen = seenReportIDs {
				for rep in (r.reports ?? []) where !seen.contains(rep.id) {
					notify(rep.isCrash ? "DevStack: \(rep.process) crashed" : "DevStack: \(rep.process) flagged for \(rep.kind ?? "resource use")",
					       rep.reason ?? (rep.isCrash ? "launchd restarts it; see devstack logs crashes." : "macOS wrote a resource report; a runaway request or job?"))
				}
			}
			seenReportIDs = ids
		}
	}

	/// Reports the developer has not dismissed yet (dismissal lasts until the app restarts).
	var activeReports: [Reports.Report] { (reports?.reports ?? []).filter { !dismissedReportIDs.contains($0.id) } }
	func dismissReports() { dismissedReportIDs.formUnion((reports?.reports ?? []).map(\.id)) }
	func openReport(_ r: Reports.Report) { if let f = r.file { openFolder(f) } }

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
		if let u = update, u.isAvailable, let head = u.commits?.first, head != notifiedUpdateHead {
			notifiedUpdateHead = head
			notify("DevStack update available", "\(u.behind ?? 0) commit\((u.behind ?? 0) == 1 ? "" : "s") waiting. Open DevStack to update.")
		}
	}

	func runDoctor() { runJob(title: "Doctor", ["doctor"]) }
	func clone(_ site: Site, as name: String, php: String?) {
		var args = ["clone", site.name, name, "--json"]
		if let php, !php.isEmpty { args += ["--php", php] }
		runJob(title: "Clone \(site.name) → \(name)", args)
	}
	func restore(_ b: BackupEntry, replace: Bool) {
		var args = ["restore", b.name, "--from", b.path, "--json"]
		if replace { args.append("--replace") }
		runJob(title: "Restore \(b.name)", args)
	}
	func siteExists(_ name: String) -> Bool { status?.sites.contains { $0.name == name } ?? false }
	func pruneBackups(keep: Int) { runJob(title: "Prune backups (keep \(keep) per site)", ["backups", "--prune", "--keep", String(keep), "--json"]) }
	func deleteBackup(_ b: BackupEntry) async {
		await quick("backup:" + b.path, ["backups", "--delete", b.path, "--json"], label: "Backup of \(b.name) from \(b.created ?? "?") deleted")
		await loadBackups()
	}
	func loadBackups() async {
		guard installed, !frozen else { return }
		loadingBackups = true
		defer { loadingBackups = false }
		backups = (try? await Devstack.runJSON([BackupEntry].self, ["backups", "--json"])) ?? []
	}
	func setBackups(_ list: [BackupEntry]) { backups = list }   // snapshot fixtures
	var backupsTotalBytes: Int { backups.reduce(0) { $0 + ($1.sizeBytes ?? 0) } }
	func openDebugLog(_ site: Site) { if let p = site.debugLog { openFolder(p) } }
	func switchPhp(_ site: Site, to version: String) { runJob(title: "\(site.name) → PHP \(version)", ["php", site.name, version, "--json"]) }
	func restartService(named name: String) async { await quick(name, ["service", name, "restart"]) }
	func startPhp(version: String) async { await quick("php@\(version)", ["service", "php@\(version)", "start"]) }

	/// The php-fpm a site needs is not running: the site answers 502 until it is started.
	func fpmProblem(for site: Site) -> String? {
		guard site.php != "default", let st = status, let p = st.php.first(where: { $0.version == site.php }) else { return nil }
		return p.fpmRunning ? nil : p.version
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

	func toggle(_ s: Service) async { await quick(s.name, ["service", s.name, s.isRunning ? "stop" : "start"], label: "\(s.name) \(s.isRunning ? "stopped" : "started")") }
	func restart(_ s: Service) async { await quick(s.name, ["service", s.name, "restart"], label: "\(s.name) restarted") }
	func toggleXdebug(_ p: PhpVersion) async { await quick("php@\(p.version)", ["xdebug", p.xdebug ? "off" : "on", "--php", p.version], label: "Xdebug \(p.xdebug ? "off" : "on") for PHP \(p.version)") }
	func toggleFpm(_ p: PhpVersion) async { await quick("php@\(p.version)", ["service", "php@\(p.version)", p.fpmRunning ? "stop" : "start"], label: "php-fpm \(p.version) \(p.fpmRunning ? "stopped" : "started")") }

	func isBusy(_ key: String) -> Bool { busy.contains(key) }

	/// A short action: spinner on the row, one notification with the outcome, then a status refresh.
	private func quick(_ key: String, _ args: [String], label: String? = nil) async {
		busy.insert(key)
		defer { busy.remove(key) }
		let r = await Devstack.run(args)
		if r.status != 0 {
			errorMessage = r.lastErrorLine
			if let label { notify("DevStack: \(label.replacingOccurrences(of: #" (started|stopped|restarted|on|off)$"#, with: "", options: .regularExpression)) failed", r.lastErrorLine) }
		} else if let label {
			notify("DevStack", label)
		}
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

	func remove(_ site: Site, backupFirst: Bool, compress: Bool = false) {
		var args = ["remove", site.name, "--yes"]
		if backupFirst { args.append("--backup"); if compress { args.append("--compress") } }
		runJob(title: backupFirst ? "Archive \(site.name)" : "Remove \(site.name)", args)
	}

	func refreshSizes() { runJob(title: "Measure site folders", ["sizes", "--refresh", "--json"]) }
	// Public URL through Cloudflare (bin/site-share). Starting is quick (seconds) but the result is a URL, so it runs
	// as a quick action and the panel shows the share line from status.
	func share(_ site: Site) async {
		await quick("share", ["share", site.name, "--json"], label: "Sharing \(site.name) publicly")
		if let url = status?.share?.url, !url.isEmpty { copy(url); open(url) }
	}
	func stopSharing() async { await quick("share", ["share", "--stop", "--json"], label: "Public sharing stopped") }
	func setCache(_ site: Site, _ backend: String) { runJob(title: "\(site.name): object cache \(backend)", ["cache", site.name, backend, "--json"]) }
	func savePoint(_ site: Site) { runJob(title: "Save point: \(site.name) database", ["backup", site.name, "--db-only", "--label", "save point", "--json"]) }
	func rollBack(_ b: BackupEntry) { runJob(title: "Roll back \(b.name) database", ["restore", b.name, "--from", b.path, "--db-only", "--json"]) }
	@Published var menuBarGraph: Bool = UserDefaults.standard.bool(forKey: "menubar.graph") {
		didSet { UserDefaults.standard.set(menuBarGraph, forKey: "menubar.graph"); sampler.start(interval: panelOpen ? 3 : (menuBarGraph ? 15 : 60)) }
	}
	func toggleFavorite(_ site: Site) async { await quick("fav:" + site.name, ["favorite", site.name, site.isFavorite ? "off" : "on", "--json"]) }

	private func runJob(title: String, _ args: [String]) {
		guard !task.running else { errorMessage = "Another task is still running."; return }
		task = TaskLog(title: title, command: "devstack " + args.joined(separator: " "), running: true)
		modal = .task
		presentModal()
		Task {
			let status = await Devstack.stream(args) { [weak self] line in
				Task { @MainActor in self?.task.lines.append(line) }
			}
			task.finish(status)
			if args.first == "update", status == 0 { update = nil }
			notify("DevStack: \(task.title)", status == 0 ? (task.result?.url.map { "Done. \($0)" } ?? "Done.") : "Failed with status \(status). Open DevStack for the log.")
			history.insert(task, at: 0)
			if history.count > 20 { history.removeLast(history.count - 20) }
			if ["backup", "restore", "clone", "backups", "remove"].contains(args.first ?? "") { await loadBackups() }
			await refresh()
		}
	}

	/// Show an earlier task's log again (only while nothing is running).
	func showHistory(_ entry: TaskLog) { guard !task.running else { return }; task = entry }

	// MARK: open things

	func open(_ url: String) {
		guard let u = URL(string: url) else { return }
		NSWorkspace.shared.open(u)
	}

	func openFolder(_ path: String) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }

	/// Editors and terminals present on this Mac, for the site menu.
	static let editorCandidates: [(name: String, path: String)] = [
		("Visual Studio Code", "/Applications/Visual Studio Code.app"), ("Cursor", "/Applications/Cursor.app"),
		("PhpStorm", "/Applications/PhpStorm.app"), ("Zed", "/Applications/Zed.app"), ("Sublime Text", "/Applications/Sublime Text.app"),
		("iTerm", "/Applications/iTerm.app"), ("Warp", "/Applications/Warp.app"), ("Ghostty", "/Applications/Ghostty.app"),
		("Terminal", "/System/Applications/Utilities/Terminal.app"),
	]
	var editors: [(name: String, path: String)] { Self.editorCandidates.filter { FileManager.default.fileExists(atPath: $0.path) } }
	func open(_ path: String, with app: String) {
		NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: URL(fileURLWithPath: app), configuration: NSWorkspace.OpenConfiguration())
	}

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


/// macOS notifications (UserNotifications). Authorization is asked once; a denied request just means silence.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
	private var ready = false

	override init() {
		super.init()
		guard Bundle.main.bundleIdentifier != nil else { return }      // only meaningful inside the .app bundle
		let center = UNUserNotificationCenter.current()
		center.delegate = self
		center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in self?.ready = granted }
	}

	func post(title: String, body: String) {
		guard ready else { return }
		let content = UNMutableNotificationContent()
		content.title = title
		content.body = body
		content.sound = .default
		UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
	}

	/// Show banners even while the app is frontmost (it rarely is, but the task window can be).
	func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
		[.banner, .sound]
	}
}
