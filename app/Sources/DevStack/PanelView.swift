// PanelView.swift — the menu-bar window: header with quick-open buttons, load chart, Sites / Services / PHP.
import SwiftUI

struct PanelView: View {
	@EnvironmentObject private var state: AppState
	@Environment(\.openWindow) private var openWindow
	@AppStorage("panel.tab") private var tab: Tab = .sites

	enum Tab: String, CaseIterable, Identifiable {
		case sites = "Sites", services = "Services", php = "PHP"
		var id: String { rawValue }
	}

	var body: some View {
		VStack(spacing: 0) {
			header.padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
			if let msg = state.errorMessage {
				ErrorLine(message: msg) { state.errorMessage = nil }.padding(.horizontal, 14).padding(.bottom, 8)
			}
			if let u = state.update, u.isAvailable {
				UpdateLine(info: u) { state.runUpdate() }.padding(.horizontal, 14).padding(.bottom, 8)
			}
			if let up = state.status?.upgrades, up.hasNews {
				StackUpgradeLine(upgrades: up, upgradeAll: { state.runUpgrade(all: true) }, upgradePatches: { state.runUpgrade(all: false) })
					.padding(.horizontal, 14).padding(.bottom, 8)
			}
			if !state.runaways.isEmpty {
				RunawayLine(runaways: state.runaways, restart: { svc in Task { await state.restartService(named: svc) } }, busy: { state.isBusy($0) })
					.padding(.horizontal, 14).padding(.bottom, 8)
			}
			if !state.activeReports.isEmpty {
				ReportsLine(reports: state.activeReports, open: { state.openReport($0) }, dismiss: { state.dismissReports() })
					.padding(.horizontal, 14).padding(.bottom, 8)
			}
			quickOpen.padding(.horizontal, 14).padding(.bottom, 10)
			UsageChart(sampler: state.sampler).padding(.horizontal, 14)
			Picker("Section", selection: $tab) {
				ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
			}
			.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 14).padding(.vertical, 10)
			Group {
				switch tab {
				case .sites: SitesView(present: present)
				case .services: ServicesView()
				case .php: PhpView()
				}
			}
			.frame(height: 292)
			Divider()
			footer.padding(.horizontal, 14).padding(.vertical, 9)
		}
		.frame(width: 400)
		.onAppear {
			state.showModalWindow = { openWindow(id: "modal"); activate() }
			state.panelDidAppear()
		}
		.onDisappear { state.panelDidDisappear() }
	}

	private var header: some View {
		HStack(alignment: .top, spacing: 8) {
			VStack(alignment: .leading, spacing: 2) {
				Text("DevStack").font(.headline)
				Text(state.status?.summary ?? (state.installed ? "Reading stack status…" : "devstack command not found"))
					.font(.caption).foregroundStyle(.secondary).lineLimit(1)
			}
			Spacer()
			Button { Task { await state.refresh() } } label: {
				if state.isRefreshing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
			}
			.buttonStyle(.borderless).frame(width: 20).help("Refresh now")
			.disabled(state.isRefreshing)
			Menu {
				Button("Open dashboard") { state.open("https://dashboard.test") }
				Button("Backups…") { present(.backups(nil)) }
				Button("Run doctor") { present(.task); state.runDoctor() }
				Divider()
				Button("Open repo folder") { state.openRepo() }
				Button("Open Sites folder") { state.openFolder(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Sites").path) }
				Divider()
				Toggle("Start at login", isOn: Binding(get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
				Toggle("Notifications", isOn: $state.notificationsEnabled)
				Text("⌃⌥D opens this panel").font(.caption)
				Button(state.checkingUpdates ? "Checking for updates…" : "Check for updates") { Task { await state.checkForUpdates() } }
					.disabled(state.checkingUpdates)
				Button(state.isBusy("upgrade-check") ? "Checking Homebrew…" : "Check Homebrew for stack upgrades") { Task { await state.checkUpgrades() } }
					.disabled(state.isBusy("upgrade-check"))
				Toggle("Apply patch upgrades nightly (03:30)", isOn: Binding(get: { state.status?.upgrades?.autoEnabled ?? false }, set: { on in Task { await state.setNightlyUpgrades(on) } }))
					.disabled(state.isBusy("upgrade-auto") || state.status?.upgrades == nil)
				Divider()
				Button("Quit DevStack") { NSApp.terminate(nil) }
			} label: {
				Image(systemName: "ellipsis.circle")
			}
			.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 20)
		}
	}

	private var quickOpen: some View {
		HStack(spacing: 8) {
			quickButton("Dashboard", "rectangle.3.group", "https://dashboard.test")
			quickButton("phpMyAdmin", "cylinder.split.1x2", "https://phpmyadmin.test")
			quickButton(mailLabel, "envelope", "http://localhost:8025")
		}
	}

	private var mailLabel: String {
		if let n = state.status?.mail.total, n > 0 { return "Mailpit (\(n))" }
		return "Mailpit"
	}

	private func quickButton(_ title: String, _ symbol: String, _ url: String) -> some View {
		Button { state.open(url) } label: {
			Label(title, systemImage: symbol).lineLimit(1).minimumScaleFactor(0.85).frame(maxWidth: .infinity)
		}
		.controlSize(.regular)
	}

	private var footer: some View {
		HStack(spacing: 8) {
			Button { present(.newSite) } label: { Label("New site…", systemImage: "plus") }
			Button { present(.importSite) } label: { Label("Import…", systemImage: "square.and.arrow.down") }
			Spacer()
			if state.task.running {
				Button { present(.task) } label: { Label("Task running", systemImage: "arrow.triangle.2.circlepath") }
					.buttonStyle(.borderless).font(.caption)
			} else if let t = state.lastUpdated {
				Text("updated \(t, style: .relative) ago").font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
			}
		}
		.controlSize(.small)
	}

	private func present(_ modal: AppState.Modal) {
		state.modal = modal
		openWindow(id: "modal")
		activate()
	}

	private func activate() {
		NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
	}
}

// MARK: - Sites

struct SitesView: View {
	@EnvironmentObject private var state: AppState
	@StateObject private var form = FormModel()
	@AppStorage("sites.sort") private var sortBySize = false
	let present: (AppState.Modal) -> Void
	private var filter: String { form.filter }

	private var sites: [Site] {
		let list = (state.status?.userSites ?? []).filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
		// Favourites always first; within each group the chosen order.
		return list.sorted { a, b in
			if a.isFavorite != b.isFavorite { return a.isFavorite }
			return sortBySize ? a.totalBytes > b.totalBytes : a.name.localizedStandardCompare(b.name) == .orderedAscending
		}
	}

	private var sizesLine: String? {
		guard let s = state.status?.sizes, (s.filesTotal ?? 0) > 0 || (s.dbTotal ?? 0) > 0 else { return nil }
		var parts: [String] = []
		if let f = s.filesTotal, f > 0 { parts.append("\(ByteCountFormatter.string(fromByteCount: Int64(f), countStyle: .file)) in ~/Sites") }
		if let d = s.dbTotal, d > 0 { parts.append("\(ByteCountFormatter.string(fromByteCount: Int64(d), countStyle: .file)) in MySQL") }
		if let at = s.computedDate { parts.append("folders measured \(at.formatted(.relative(presentation: .named)))") }
		return parts.joined(separator: "  ·  ")
	}

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 6) {
				TextField("Filter sites", text: $form.filter).textFieldStyle(.roundedBorder).controlSize(.small)
				Picker("Sort", selection: $sortBySize) {
					Text("A–Z").tag(false)
					Text("Size").tag(true)
				}
				.pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 90)
				.help("Sort by name or by disk footprint (folder + database)")
			}
			.padding(.horizontal, 14).padding(.bottom, 6)
			if state.status == nil {
				Spacer(); ProgressView().controlSize(.small); Spacer()
			} else if sites.isEmpty {
				Spacer()
				Text(filter.isEmpty ? "No sites yet. Create one with New site…" : "No site matches “\(filter)”.")
					.font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
				Spacer()
			} else {
				ScrollView {
					LazyVStack(spacing: 0) {
						ForEach(sites) { site in SiteRow(site: site, present: present) }
					}
					.padding(.bottom, 4)
				}
				Divider().padding(.horizontal, 14)
				HStack(spacing: 6) {
					Text(sizesLine ?? "Folder sizes not measured yet.").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
					Spacer()
					Button(state.task.running ? "Measuring…" : "Measure") { present(.task); state.refreshSizes() }
						.buttonStyle(.borderless).font(.caption2).disabled(state.task.running)
						.help("Walk every site folder with du (minutes); the 03:30 run does this nightly")
				}
				.padding(.horizontal, 14).padding(.vertical, 5)
			}
		}
	}
}

struct SiteRow: View {
	@EnvironmentObject private var state: AppState
	let site: Site
	let present: (AppState.Modal) -> Void

	private var fpmStopped: String? { state.fpmProblem(for: site) }

	private var fatals: Int { site.fatalsRecent ?? 0 }

	private var subtitle: String {
		var parts = ["PHP \(site.php == "default" ? (state.status?.defaultPhp?.version ?? "default") : site.php)"]
		if let v = fpmStopped { parts[0] += " (php-fpm \(v) stopped)" }
		parts.append(site.wp ? "WordPress" : "PHP / static")
		if site.isProtected { parts.append("protected") }
		if let size = site.sizeText { parts.append(size) }
		if fatals > 0 { parts.append("\(fatals) fatal\(fatals == 1 ? "" : "s") in debug.log") }
		return parts.joined(separator: "  ·  ")
	}

	var body: some View {
		Row(title: site.name + (site.isFavorite ? "  ★" : ""), subtitle: subtitle) {
			if fatals > 0 && fpmStopped == nil {
				Image(systemName: "exclamationmark.circle.fill").font(.caption).frame(width: 12).foregroundStyle(Color.red)
					.help("\(fatals) PHP fatal error\(fatals == 1 ? "" : "s") logged today or yesterday; ⋯ → Open debug.log")
			} else if fpmStopped != nil {
				Image(systemName: "exclamationmark.triangle.fill").font(.caption).frame(width: 12).foregroundStyle(Color.orange)
					.help("This site's PHP version is not running; it answers 502 until it is started")
			} else {
				Image(systemName: site.isProtected ? "shield.lefthalf.filled" : (site.secured ? "lock.fill" : "lock.open"))
					.font(.caption).frame(width: 12)
					.foregroundStyle(site.isProtected ? Color.orange : (site.secured ? Color.green : Color.secondary))
					.help(site.isProtected ? "Protected site: never removed by tooling" : (site.secured ? "HTTPS" : "HTTP only"))
			}
		} trailing: {
			if state.isBusy(site.name) { ProgressView().controlSize(.mini).frame(width: 16) }
			Button { state.open(site.url) } label: { Image(systemName: "safari") }
				.buttonStyle(.borderless).help("Open \(site.url)")
			if site.wp {
				Button { Task { await state.login(siteNamed: site.name) } } label: { Image(systemName: "person.badge.key") }
					.buttonStyle(.borderless).help("Log in to wp-admin (one-time link)")
			}
			Menu {
				if let v = fpmStopped {
					Button("Start PHP \(v) (site is down)") { Task { await state.startPhp(version: v) } }
					Divider()
				}
				Button(site.isFavorite ? "Remove from favourites" : "Add to favourites") { Task { await state.toggleFavorite(site) } }
				Divider()
				Button("Log in to wp-admin") { Task { await state.login(siteNamed: site.name) } }.disabled(!site.wp)
				Button("Open wp-admin") { state.open(site.adminUrl) }.disabled(!site.wp)
				Button("Open folder") { state.openFolder(site.path) }
				ForEach(state.editors, id: \.path) { e in
					Button("Open in \(e.name)") { state.open(site.path, with: e.path) }
				}
				Button("Copy URL") { state.copy(site.url) }
				if site.debugLog != nil { Button(fatals > 0 ? "Open debug.log (\(fatals) fatals)" : "Open debug.log") { state.openDebugLog(site) } }
				Divider()
				Menu("PHP version") {
					ForEach(state.status?.php ?? []) { p in
						let current = site.php == p.version || (site.php == "default" && p.isDefault)
						Button {
							state.switchPhp(site, to: p.isDefault ? "default" : p.version)
						} label: {
							if current { Label("PHP \(p.version)\(p.isDefault ? " (default)" : "")", systemImage: "checkmark") } else { Text("PHP \(p.version)\(p.isDefault ? " (default)" : "")") }
						}
						.disabled(current || site.isProtected)
					}
				}
				Button("Back up now") { state.backup(site) }
				Button("Restore from backup…") { present(.backups(site.name)) }
				Button("Duplicate…") { present(.clone(site)) }
				Divider()
				Button("Archive (back up, then remove)…") { present(.remove(site)) }.disabled(site.isProtected)
			} label: {
				Image(systemName: "ellipsis.circle")
			}
			.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 18)
		}
	}
}

// MARK: - Services

struct ServicesView: View {
	@EnvironmentObject private var state: AppState

	var body: some View {
		VStack(spacing: 0) {
			ScrollView {
				LazyVStack(spacing: 0) {
					ForEach(state.status?.coreServices ?? []) { s in ServiceRow(service: s) }
				}
			}
			if let ports = state.status?.portsLine, !ports.isEmpty {
				Divider().padding(.horizontal, 14)
				Text(ports).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
					.padding(.horizontal, 14).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
			}
		}
	}
}

struct ServiceRow: View {
	@EnvironmentObject private var state: AppState
	let service: Service

	var body: some View {
		let busy = state.isBusy(service.name)
		Row(title: service.name, subtitle: service.subtitle) {
			StatusDot(kind: busy ? .busy : (service.isError ? .error : (service.isRunning ? .on : .off)))
		} trailing: {
			Button { Task { await state.restart(service) } } label: { Image(systemName: "arrow.clockwise") }
				.buttonStyle(.borderless).help("Restart \(service.name)").disabled(busy || !service.isRunning)
			Toggle("", isOn: Binding(get: { service.isRunning }, set: { _ in Task { await state.toggle(service) } }))
				.toggleStyle(.switch).controlSize(.mini).labelsHidden().disabled(busy)
		}
	}
}

// MARK: - PHP

struct PhpView: View {
	@EnvironmentObject private var state: AppState

	var body: some View {
		ScrollView {
			LazyVStack(spacing: 0) {
				ForEach(state.status?.php ?? []) { p in PhpRow(php: p) }
			}
		}
	}
}

struct PhpRow: View {
	@EnvironmentObject private var state: AppState
	let php: PhpVersion

	private var subtitle: String {
		var parts: [String] = [php.full]
		if php.isDefault { parts.append("default") }
		parts.append(php.sites == 1 ? "1 site" : "\(php.sites) sites")
		parts.append(php.fpmRunning ? "fpm running" : "fpm off")
		return parts.joined(separator: "  ·  ")
	}

	var body: some View {
		let busy = state.isBusy("php@\(php.version)")
		Row(title: "PHP \(php.version)", subtitle: subtitle) {
			StatusDot(kind: busy ? .busy : (php.fpmRunning ? .on : .off))
		} trailing: {
			Toggle("Xdebug", isOn: Binding(get: { php.xdebug }, set: { _ in Task { await state.toggleXdebug(php) } }))
				.toggleStyle(.checkbox).controlSize(.small).disabled(busy)
				.help("Xdebug in trigger mode on port 9003 (restarts php-fpm \(php.version))")
			Toggle("", isOn: Binding(get: { php.fpmRunning }, set: { _ in Task { await state.toggleFpm(php) } }))
				.toggleStyle(.switch).controlSize(.mini).labelsHidden().disabled(busy || php.isDefault)
				.help(php.isDefault ? "The default version always runs" : (php.fpmRunning ? "Stop php-fpm \(php.version)" : "Start php-fpm \(php.version)"))
		}
	}
}
