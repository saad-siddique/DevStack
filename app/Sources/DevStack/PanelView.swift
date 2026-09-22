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
				Button("Open repo folder") { state.openRepo() }
				Button("Open Sites folder") { state.openFolder(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Sites").path) }
				Divider()
				Toggle("Start at login", isOn: Binding(get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
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
	let present: (AppState.Modal) -> Void
	private var filter: String { form.filter }

	private var sites: [Site] {
		(state.status?.userSites ?? []).filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
	}

	var body: some View {
		VStack(spacing: 0) {
			TextField("Filter sites", text: $form.filter)
				.textFieldStyle(.roundedBorder).controlSize(.small)
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
			}
		}
	}
}

struct SiteRow: View {
	@EnvironmentObject private var state: AppState
	let site: Site
	let present: (AppState.Modal) -> Void

	private var subtitle: String {
		var parts = ["PHP \(site.php == "default" ? (state.status?.defaultPhp?.version ?? "default") : site.php)"]
		parts.append(site.wp ? "WordPress" : "PHP / static")
		if site.isProtected { parts.append("protected") }
		return parts.joined(separator: "  ·  ")
	}

	var body: some View {
		Row(title: site.name, subtitle: subtitle) {
			Image(systemName: site.isProtected ? "shield.lefthalf.filled" : (site.secured ? "lock.fill" : "lock.open"))
				.font(.caption).frame(width: 12)
				.foregroundStyle(site.isProtected ? Color.orange : (site.secured ? Color.green : Color.secondary))
				.help(site.isProtected ? "Protected site: never removed by tooling" : (site.secured ? "HTTPS" : "HTTP only"))
		} trailing: {
			Button { state.open(site.url) } label: { Image(systemName: "safari") }
				.buttonStyle(.borderless).help("Open \(site.url)")
			Menu {
				Button("Open wp-admin") { state.open(site.adminUrl) }.disabled(!site.wp)
				Button("Open folder") { state.openFolder(site.path) }
				Button("Copy URL") { state.copy(site.url) }
				Divider()
				Button("Back up now") { state.backup(site) }
				Button("Remove…", role: .destructive) { present(.remove(site)) }.disabled(site.isProtected)
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
