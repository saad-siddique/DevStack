// PanelView.swift — the menu-bar window: header with quick-open buttons, load chart, Sites / Services / PHP.
import SwiftUI

struct PanelView: View {
	@EnvironmentObject private var state: AppState
	@Environment(\.openWindow) private var openWindow
	@Environment(\.colorScheme) private var scheme
	@AppStorage("panel.tab") private var tab: Tab = .sites

	enum Tab: String, CaseIterable, Identifiable {
		case sites = "Sites", services = "Services", php = "PHP"
		var id: String { rawValue }
	}

	var body: some View {
		let t = Theme(scheme)
		VStack(spacing: 0) {
			hero
			VStack(spacing: 10) {
				if let msg = state.errorMessage { ErrorLine(message: msg) { state.errorMessage = nil } }
				if let u = state.update, u.isAvailable { UpdateLine(info: u) { state.runUpdate() } }
				if let up = state.status?.upgrades, up.hasNews {
					StackUpgradeLine(upgrades: up, upgradeAll: { state.runUpgrade(all: true) }, upgradePatches: { state.runUpgrade(all: false) })
				}
				if let sh = state.status?.share {
					ShareLine(share: sh, copy: { state.copy($0) }, open: { state.open($0) }, stop: { Task { await state.stopSharing() } }, busy: state.isBusy("share"))
				}
				if !state.runaways.isEmpty {
					RunawayLine(runaways: state.runaways, restart: { svc in Task { await state.restartService(named: svc) } }, busy: { state.isBusy($0) })
				}
				if !state.activeReports.isEmpty {
					ReportsLine(reports: state.activeReports, open: { state.openReport($0) }, dismiss: { state.dismissReports() })
				}
				Card { quickOpen }
				Card(padding: 12) { UsageChart(sampler: state.sampler) }
				Picker("Section", selection: $tab) {
					ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
				}
				.pickerStyle(.segmented).labelsHidden()
				Card {
					Group {
						switch tab {
						case .sites: SitesView(present: present)
						case .services: ServicesView()
						case .php: PhpView()
						}
					}
					.frame(height: 292)
					.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
				}
			}
			.padding(12)
			footer.padding(.horizontal, 14).padding(.bottom, 10)
		}
		.frame(width: 400)
		.background(t.dark ? Color.black.opacity(0.18) : Color.white.opacity(0.28))   // tint on the popover's own material: one continuous glass
		.tint(t.accent)
		.ignoresSafeArea()
		.onAppear {
			state.showModalWindow = { openWindow(id: "modal"); activate() }
			state.panelDidAppear()
		}
		.onDisappear { state.panelDidDisappear() }
	}

	/// Short enough to sit beside the CPU figure: "6/6 up · 7 sites · PHP 8.4".
	private var heroSummary: String {
		guard state.installed else { return "devstack command not found" }
		guard let st = state.status else { return "Reading stack status…" }
		var parts = ["\(st.onlineCount)/\(st.coreServices.count) up", "\(st.userSites.count) sites"]
		if let d = st.defaultPhp { parts.append("PHP \(d.version)") }
		return parts.joined(separator: " · ")
	}

	/// Gradient header: the stack glyph, name and summary, live CPU and memory, refresh and the ⋯ menu.
	private var hero: some View {
		let t = Theme(scheme)
		return HStack(spacing: 12) {
			ZStack {
				RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.14))
				if let img = NSImage(named: "MenuBarIcon") {
					let _ = { img.isTemplate = true }()
					Image(nsImage: img).renderingMode(.template).resizable().frame(width: 20, height: 20).foregroundStyle(.white)
				}
			}
			.frame(width: 34, height: 34)
			VStack(alignment: .leading, spacing: 2) {
				Text("DevStack").font(.system(size: 15, weight: .semibold)).foregroundStyle(t.heroText)
				Text(heroSummary).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(t.heroMuted).lineLimit(1)
			}
			Spacer(minLength: 4)
			if let sample = state.sampler.samples.last {
				VStack(alignment: .trailing, spacing: 0) {
					Text("\(sample.cpu, specifier: "%.1f")%").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(t.heroText).monospacedDigit()
					Text("\(Int(sample.memoryMB)) MB").font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundStyle(t.heroMuted).monospacedDigit()
				}
			}
			VStack(spacing: 6) {
				Button { Task { await state.refresh() } } label: {
					if state.isRefreshing { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold)) }
				}
				.buttonStyle(.plain).foregroundStyle(t.heroMuted).frame(width: 18, height: 14).help("Refresh now").disabled(state.isRefreshing)
				panelMenu
			}
		}
		.padding(.horizontal, 16).padding(.vertical, 14)
		.background(t.hero.ignoresSafeArea(edges: .top))
	}

	private var panelMenu: some View {
		let t = Theme(scheme)
		return Menu {
				Button("Open dashboard") { state.open("https://dashboard.test") }
				Button("Backups…") { present(.backups(nil)) }
				Button("Run doctor") { present(.task); state.runDoctor() }
				Divider()
				Button("Open repo folder") { state.openRepo() }
				Button("Open Sites folder") { state.openFolder(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Sites").path) }
				Divider()
				Toggle("Start at login", isOn: Binding(get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
				Toggle("Notifications", isOn: $state.notificationsEnabled)
				Toggle("Show load graph in the menu bar", isOn: $state.menuBarGraph)
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
			Image(systemName: "ellipsis.circle").font(.system(size: 13, weight: .semibold)).foregroundStyle(t.heroMuted)
		}
		.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 18, height: 14)
	}

	private var quickOpen: some View {
		let t = Theme(scheme)
		return HStack(spacing: 0) {
			quickButton("Dashboard", "rectangle.3.group", "https://dashboard.test")
			Rectangle().fill(t.divider).frame(width: 1, height: 22)
			quickButton("phpMyAdmin", "cylinder.split.1x2", "https://phpmyadmin.test")
			Rectangle().fill(t.divider).frame(width: 1, height: 22)
			quickButton(mailLabel, "envelope", "http://localhost:8025")
		}
	}

	private var mailLabel: String {
		if let n = state.status?.mail.total, n > 0 { return "Mailpit (\(n))" }
		return "Mailpit"
	}

	private func quickButton(_ title: String, _ symbol: String, _ url: String) -> some View {
		Button { state.open(url) } label: {
			Label(title, systemImage: symbol).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme(scheme).accent)
				.lineLimit(1).minimumScaleFactor(0.85).frame(maxWidth: .infinity).padding(.vertical, 10).contentShape(Rectangle())
		}
		.buttonStyle(.plain)
	}

	private var footer: some View {
		let t = Theme(scheme)
		return HStack(spacing: 14) {
			Button { present(.newSite) } label: { Label("New site", systemImage: "plus") }
			Button { present(.importSite) } label: { Label("Import", systemImage: "square.and.arrow.down") }
			Spacer()
			if state.task.running {
				Button { present(.task) } label: { Label("Task running", systemImage: "arrow.triangle.2.circlepath") }
			} else if let at = state.lastUpdated {
				Text("updated \(at, style: .relative) ago").font(.system(size: 10.5, design: .rounded)).foregroundStyle(t.faint).monospacedDigit()
			}
		}
		.buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(t.accent)
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
	@Environment(\.colorScheme) private var scheme
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
		let t = Theme(scheme)
		VStack(spacing: 0) {
			HStack(spacing: 8) {
				Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(t.faint)
				TextField("Filter sites", text: $form.filter).textFieldStyle(.plain).font(.system(size: 12.5))
				Picker("Sort", selection: $sortBySize) {
					Text("A–Z").tag(false)
					Text("Size").tag(true)
				}
				.pickerStyle(.segmented).labelsHidden().controlSize(.mini).frame(width: 84)
				.help("Sort by name or by disk footprint (folder + database)")
			}
			.padding(.horizontal, 12).padding(.vertical, 8)
			.overlay(alignment: .bottom) { Rectangle().fill(t.divider).frame(height: 1) }
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
				HStack(spacing: 6) {
					Text(sizesLine ?? "Folder sizes not measured yet.").font(.system(size: 10.5, design: .rounded)).foregroundStyle(t.faint).lineLimit(1)
					Spacer()
					Button(state.task.running ? "Measuring…" : "Measure") { present(.task); state.refreshSizes() }
						.buttonStyle(.plain).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(t.accent).disabled(state.task.running)
						.help("Walk every site folder with du (minutes); the 03:30 run does this nightly")
				}
				.padding(.horizontal, 12).padding(.vertical, 6)
				.overlay(alignment: .top) { Rectangle().fill(t.divider).frame(height: 1) }
			}
		}
	}
}

struct SiteRow: View {
	@EnvironmentObject private var state: AppState
	@Environment(\.colorScheme) private var scheme
	let site: Site
	let present: (AppState.Modal) -> Void

	private var fpmStopped: String? { state.fpmProblem(for: site) }

	private var fatals: Int { site.fatalsRecent ?? 0 }

	/// One quiet line under the name: version, footprint, then anything unusual.
	private var subtitle: String {
		var parts = ["PHP \(site.php == "default" ? (state.status?.defaultPhp?.version ?? "default") : site.php)"]
		if let v = fpmStopped { parts[0] += " (php-fpm \(v) stopped)" }
		if let size = site.sizeText { parts.append(size) }
		if !site.wp { parts.append("static") }
		if let oc = site.objectCache { parts.append(oc) }
		if site.isProtected { parts.append("protected") }
		if !site.secured { parts.append("http only") }
		if fatals > 0 { parts.append("\(fatals) fatal\(fatals == 1 ? "" : "s") today") }
		return parts.joined(separator: " · ")
	}

	private var tile: Tile {
		if fpmStopped != nil { return Tile(text: "", symbol: "exclamationmark.triangle.fill", kind: .warn) }
		if fatals > 0 { return Tile(text: "", symbol: "exclamationmark", kind: .bad) }
		return Tile(text: String(site.name.prefix(1)).uppercased())
	}

	var body: some View {
		let t = Theme(scheme)
		Row(title: site.name, subtitle: subtitle, star: site.isFavorite) {
			tile.help(fpmStopped != nil ? "This site's PHP version is not running; it answers 502 until it is started"
			          : (fatals > 0 ? "\(fatals) PHP fatal error\(fatals == 1 ? "" : "s") logged today or yesterday; ⋯ → Open debug.log" : site.url))
		} trailing: {
			if state.isBusy(site.name) { ProgressView().controlSize(.mini).frame(width: 16) }
			Button { state.open(site.url) } label: { Image(systemName: "safari").font(.system(size: 12)) }
				.buttonStyle(.plain).foregroundStyle(t.muted).help("Open \(site.url)")
			if site.wp {
				Button { state.open(site.adminUrl) } label: { Image(systemName: "gearshape").font(.system(size: 12)) }
					.buttonStyle(.plain).foregroundStyle(t.muted).help("Open wp-admin")
				Button { Task { await state.login(siteNamed: site.name) } } label: { Image(systemName: "person.badge.key").font(.system(size: 12)) }
					.buttonStyle(.plain).foregroundStyle(t.muted).help("Log in to wp-admin (one-time link)")
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
				if site.wp {
					Menu("Object cache") {
						ForEach(["redis", "memcached", "off"], id: \.self) { b in
							let current = (site.objectCache ?? "off") == b
							Button { state.setCache(site, b) } label: { current ? Label(b.capitalized, systemImage: "checkmark") : Label(b.capitalized, systemImage: "") }
								.disabled(current)
						}
					}
					Button(state.status?.share != nil && (state.status?.share?.sites ?? []).contains(site.name) ? "Sharing publicly…" : "Share publicly (Cloudflare tunnel)") { Task { await state.share(site) } }
						.disabled(state.isBusy("share"))
					Divider()
					Button("Save point (database)") { present(.task); state.savePoint(site) }
				}
				Button("Back up now") { state.backup(site) }
				Button("Restore from backup…") { present(.backups(site.name)) }
				Button("Duplicate…") { present(.clone(site)) }
				Divider()
				Button("Archive (back up, then remove)…") { present(.remove(site)) }.disabled(site.isProtected)
			} label: {
				Image(systemName: "ellipsis.circle").font(.system(size: 12)).foregroundStyle(t.muted)
			}
			.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 18)
		}
	}
}

// MARK: - Services

struct ServicesView: View {
	@EnvironmentObject private var state: AppState
	@Environment(\.colorScheme) private var scheme

	var body: some View {
		VStack(spacing: 0) {
			ScrollView {
				LazyVStack(spacing: 0) {
					ForEach(state.status?.coreServices ?? []) { s in ServiceRow(service: s) }
				}
			}
			if let ports = state.status?.portsLine, !ports.isEmpty {
				Text(ports).font(.system(size: 10.5, design: .rounded)).foregroundStyle(Theme(scheme).faint).lineLimit(2)
					.padding(.horizontal, 12).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
					.overlay(alignment: .top) { Rectangle().fill(Theme(scheme).divider).frame(height: 1) }
			}
		}
	}
}

struct ServiceRow: View {
	@EnvironmentObject private var state: AppState
	@Environment(\.colorScheme) private var scheme
	let service: Service

	var body: some View {
		let busy = state.isBusy(service.name)
		Row(title: service.name, subtitle: service.subtitle) {
			StatusDot(kind: busy ? .busy : (service.isError ? .error : (service.isRunning ? .on : .off)))
		} trailing: {
			Button { Task { await state.restart(service) } } label: { Image(systemName: "arrow.clockwise").font(.system(size: 12)) }
				.buttonStyle(.plain).foregroundStyle(Theme(scheme).muted).help("Restart \(service.name)").disabled(busy || !service.isRunning)
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
