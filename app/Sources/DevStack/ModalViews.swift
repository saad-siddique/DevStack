// ModalViews.swift — the one ordinary window: New site, Import, Remove confirmation, and the live task log.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ModalView: View {
	@EnvironmentObject private var state: AppState

	var body: some View {
		Group {
			switch state.modal {
			case .newSite: NewSiteView()
			case .importSite: ImportSiteView()
			case .remove(let site): RemoveSiteView(site: site)
			case .clone(let site): CloneSiteView(site: site)
			case .backups(let filter): BackupsView(initialFilter: filter ?? "")
			case .panel: PanelView()
			case .task: TaskView()
			case nil: Text("Nothing to show.").foregroundStyle(.secondary).padding(40)
			}
		}
	}
}

private let nameRule = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9-]*$")
private func isValidName(_ s: String) -> Bool { nameRule.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

struct PhpPicker: View {
	@EnvironmentObject private var state: AppState
	@Binding var selection: String
	var allowAuto = false

	var body: some View {
		Picker("PHP version", selection: $selection) {
			if allowAuto { Text("From the source, else default").tag("") }
			ForEach(state.status?.php ?? []) { p in
				Text(p.isDefault ? "PHP \(p.version)  (default)" : "PHP \(p.version)").tag(p.version)
			}
		}
	}
}

// MARK: - New site

/// Form state as a tiny ObservableObject: the 2026 SDK implements @State as a macro that the Command Line Tools
/// cannot expand, and this keeps the app buildable without a full Xcode.
final class FormModel: ObservableObject {
	@Published var name = "" { didSet { let c = name.lowercased().replacingOccurrences(of: " ", with: "-"); if c != name { name = c } } }
	@Published var php = ""
	@Published var empty = false
	@Published var source = ""
	@Published var sql = ""
	@Published var backupFirst = true
	@Published var filter = ""
	@Published var adminUser = "admin"
	@Published var adminPassword = "admin1"
	@Published var adminEmail = "admin@example.test"
	@Published var keep = 5
	@Published var compress = false
}

struct NewSiteView: View {
	@EnvironmentObject private var state: AppState
	@Environment(\.dismiss) private var dismiss
	@StateObject private var form = FormModel()
	private var name: String { form.name }
	private var php: String { form.php }
	private var empty: Bool { form.empty }

	private var taken: Bool { state.status?.sites.contains { $0.name == name } ?? false }
	private var adminOK: Bool { empty || (!form.adminUser.isEmpty && !form.adminPassword.isEmpty && form.adminEmail.contains("@")) }
	private var canCreate: Bool { isValidName(name) && !taken && !php.isEmpty && adminOK }

	var body: some View {
		Form {
			Section {
				TextField("Name", text: $form.name, prompt: Text("myplugin"))
				LabeledContent("Address") {
					Text(name.isEmpty ? "https://<name>.test" : "https://\(name).test").foregroundStyle(.secondary).textSelection(.enabled)
				}
				PhpPicker(selection: $form.php)
				Toggle("Empty folder only (no WordPress download)", isOn: $form.empty)
			}
			Section("wp-admin account") {
				TextField("Username", text: $form.adminUser)
				TextField("Password", text: $form.adminPassword)
				TextField("Email", text: $form.adminEmail)
			}
			.disabled(empty)
			if taken {
				Text("A site called “\(name)” already exists.").foregroundStyle(.red).font(.callout)
			} else if !name.isEmpty && !isValidName(name) {
				Text("Lowercase letters, digits and dashes only.").foregroundStyle(.red).font(.callout)
			} else {
				Text(empty ? "Creates ~/Sites/\(name.isEmpty ? "<name>" : name) with a placeholder index.php, links and secures it."
				           : "Downloads WordPress, creates its database and user, installs it with the wp-admin account above and secures it. The task log ends with a Log in button.")
					.foregroundStyle(.secondary).font(.callout)
			}
		}
		.formStyle(.grouped)
		.safeAreaInset(edge: .bottom) {
			FormFooter(cancel: { dismiss() }, action: "Create site", enabled: canCreate) {
				state.createSite(name: name, php: php, empty: empty, adminUser: form.adminUser, adminPassword: form.adminPassword, adminEmail: form.adminEmail)
			}
		}
		.frame(width: 480, height: 470)
		.navigationTitle("New site")
		.onAppear { if form.php.isEmpty { form.php = state.status?.defaultPhp?.version ?? "" } }
	}
}

/// Cancel + primary action, pinned under a scrolling grouped Form.
struct FormFooter: View {
	let cancel: () -> Void
	let action: String
	let enabled: Bool
	let perform: () -> Void

	var body: some View {
		HStack {
			Spacer()
			Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
			Button(action, action: perform).keyboardShortcut(.defaultAction).disabled(!enabled)
		}
		.padding(.horizontal, 20).padding(.vertical, 12)
		.background(.bar)
	}
}

// MARK: - Import

struct ImportSiteView: View {
	@EnvironmentObject private var state: AppState
	@Environment(\.dismiss) private var dismiss
	@StateObject private var form = FormModel()
	private var name: String { form.name }
	private var source: String { form.source }
	private var sql: String { form.sql }
	private var php: String { form.php }

	private var taken: Bool { state.status?.sites.contains { $0.name == name } ?? false }
	private var canImport: Bool { isValidName(name) && !taken && !source.isEmpty }

	var body: some View {
		Form {
			TextField("Name", text: $form.name, prompt: Text("client-site"))
			LabeledContent("Source") {
				HStack {
					Text(source.isEmpty ? "LocalWP export .zip, a WordPress folder, or a devstack backup" : abbreviate(source))
						.foregroundStyle(source.isEmpty ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
					Spacer()
					Button("Choose…") { choose(files: true, folders: true, types: [.zip]) { form.source = $0; suggestName(from: $0) } }
				}
			}
			LabeledContent("Database") {
				HStack {
					Text(sql.isEmpty ? "Found inside the source (largest .sql or .sql.gz)" : abbreviate(sql))
						.foregroundStyle(sql.isEmpty ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
					Spacer()
					if !sql.isEmpty { Button("Clear") { form.sql = "" } }
					Button("Choose…") { choose(files: true, folders: false, types: [UTType(filenameExtension: "sql") ?? .data, .gzip]) { form.sql = $0 } }
				}
			}
			PhpPicker(selection: $form.php, allowAuto: true)
			if taken {
				Text("A site called “\(name)” already exists.").foregroundStyle(.red).font(.callout)
			} else {
				Text("Copies the files to ~/Sites/\(name.isEmpty ? "<name>" : name), imports the dump into a fresh database, rewrites every old URL to https://\(name.isEmpty ? "<name>" : name).test and secures the site.")
					.foregroundStyle(.secondary).font(.callout)
			}
		}
		.formStyle(.grouped)
		.safeAreaInset(edge: .bottom) {
			FormFooter(cancel: { dismiss() }, action: "Import site", enabled: canImport) { state.importSite(name: name, source: source, sql: sql, php: php) }
		}
		.frame(width: 520, height: 360)
		.navigationTitle("Import site")
	}

	private func suggestName(from path: String) {
		guard name.isEmpty else { return }
		var base = (path as NSString).lastPathComponent
		if let dot = base.range(of: ".zip") { base = String(base[..<dot.lowerBound]) }
		if let stamp = try? NSRegularExpression(pattern: "^\\d{8}-\\d{6}$"), stamp.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)) != nil {
			base = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent   // backup folder → its site name
		}
		form.name = base.lowercased().replacingOccurrences(of: "[^a-z0-9-]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
	}
}

private func abbreviate(_ path: String) -> String {
	(path as NSString).abbreviatingWithTildeInPath
}

private func choose(files: Bool, folders: Bool, types: [UTType], _ done: (String) -> Void) {
	let panel = NSOpenPanel()
	panel.canChooseFiles = files
	panel.canChooseDirectories = folders
	panel.allowsMultipleSelection = false
	panel.allowedContentTypes = folders ? types + [.folder] : types
	panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
	if panel.runModal() == .OK, let url = panel.url { done(url.path) }
}

// MARK: - Clone

struct CloneSiteView: View {
	@EnvironmentObject private var state: AppState
	@Environment(\.dismiss) private var dismiss
	let site: Site
	@StateObject private var form = FormModel()

	private var taken: Bool { state.siteExists(form.name) }
	private var canClone: Bool { isValidName(form.name) && !taken && form.name != site.name }

	var body: some View {
		Form {
			LabeledContent("Source") { Text(site.url).foregroundStyle(.secondary) }
			TextField("New name", text: $form.name, prompt: Text("\(site.name)-copy"))
			LabeledContent("Address") { Text(form.name.isEmpty ? "https://<name>.test" : "https://\(form.name).test").foregroundStyle(.secondary) }
			PhpPicker(selection: $form.php, allowAuto: true)
			if taken { Text("A site called “\(form.name)” already exists.").foregroundStyle(.red).font(.callout) }
			else {
				Text("Backs \(site.name) up (the backup is kept), then imports that backup as the new site: own database and user, every URL rewritten to the new address, same logins.")
					.foregroundStyle(.secondary).font(.callout)
			}
		}
		.formStyle(.grouped)
		.safeAreaInset(edge: .bottom) {
			FormFooter(cancel: { dismiss() }, action: "Clone site", enabled: canClone) { state.clone(site, as: form.name, php: form.php) }
		}
		.frame(width: 480, height: 330)
		.navigationTitle("Duplicate \(site.name)")
	}
}

// MARK: - Backups

struct BackupsView: View {
	@EnvironmentObject private var state: AppState
	@Environment(\.dismiss) private var dismiss
	let initialFilter: String
	@StateObject private var form = FormModel()
	@StateObject private var pending = PendingAction()

	final class PendingAction: ObservableObject {
		@Published var restoreReplacing: BackupEntry?
		@Published var deleting: BackupEntry?
	}

	private var rows: [BackupEntry] {
		let f = form.filter.trimmingCharacters(in: .whitespaces)
		return state.backups.filter { f.isEmpty || $0.name.localizedCaseInsensitiveContains(f) }
	}

	var body: some View {
		VStack(spacing: 0) {
			HStack {
				TextField("Filter by site", text: $form.filter).textFieldStyle(.roundedBorder).frame(width: 220)
				Spacer()
				Text("\(state.backups.count) backup\(state.backups.count == 1 ? "" : "s"), \(ByteCountFormatter.string(fromByteCount: Int64(state.backupsTotalBytes), countStyle: .file))")
					.font(.callout).foregroundStyle(.secondary)
				Button("Keep newest 5 per site") { state.pruneBackups(keep: 5) }.help("Delete older backups; the newest of every site always stays")
				Button { Task { await state.loadBackups() } } label: { Image(systemName: "arrow.clockwise") }.disabled(state.loadingBackups)
			}
			.padding(14)
			Divider()
			if state.loadingBackups && state.backups.isEmpty {
				Spacer(); ProgressView().controlSize(.small); Spacer()
			} else if rows.isEmpty {
				Spacer()
				Text(form.filter.isEmpty ? "No backups yet. Use “Back up now” on a site." : "No backups for “\(form.filter)”.").foregroundStyle(.secondary)
				Spacer()
			} else {
				ScrollView {
					LazyVStack(spacing: 0) {
						ForEach(rows) { b in backupRow(b) }
					}
				}
			}
			Divider()
			HStack {
				Text("A restore recreates the site exactly as it was: same address, PHP version, database and logins.").font(.caption).foregroundStyle(.secondary)
				Spacer()
				Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
			}
			.padding(12)
		}
		.frame(width: 640, height: 440)
		.navigationTitle("Backups")
		.onAppear { form.filter = initialFilter; Task { await state.loadBackups() } }
		.alert("Replace the current “\(pending.restoreReplacing?.name ?? "")”?", isPresented: Binding(get: { pending.restoreReplacing != nil }, set: { if !$0 { pending.restoreReplacing = nil } })) {
			Button("Back up current, then restore", role: .destructive) { if let b = pending.restoreReplacing { state.restore(b, replace: true) }; pending.restoreReplacing = nil }
			Button("Cancel", role: .cancel) { pending.restoreReplacing = nil }
		} message: {
			Text("The site exists. A safety backup of its current state is taken first, then it is removed and this backup is restored over it.")
		}
		.alert("Delete this backup?", isPresented: Binding(get: { pending.deleting != nil }, set: { if !$0 { pending.deleting = nil } })) {
			Button("Delete", role: .destructive) { if let b = pending.deleting { Task { await state.deleteBackup(b) } }; pending.deleting = nil }
			Button("Cancel", role: .cancel) { pending.deleting = nil }
		} message: {
			Text("\(pending.deleting?.name ?? "") from \(pending.deleting?.createdDate?.formatted(date: .abbreviated, time: .shortened) ?? "?") (\(pending.deleting?.sizeText ?? "")). This cannot be undone.")
		}
	}

	private func backupRow(_ b: BackupEntry) -> some View {
		let exists = state.siteExists(b.name)
		return HStack(spacing: 10) {
			Image(systemName: b.restorable ? "externaldrive.fill" : "cylinder.split.1x2").foregroundStyle(.secondary).frame(width: 16)
			VStack(alignment: .leading, spacing: 1) {
				HStack(spacing: 6) {
					Text(b.name).fontWeight(.medium)
					if !exists { Text("site absent").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1).background(Color.orange.opacity(0.15), in: Capsule()) }
				}
				Text([b.createdDate?.formatted(date: .abbreviated, time: .shortened) ?? "?", b.sizeText, b.php.map { "PHP \($0.replacingOccurrences(of: "php@", with: ""))" }, b.tables.map { "\($0) tables" }, b.isCompressed ? "files (compressed) + database" : (b.restorable ? "files + database" : "database only")]
					.compactMap { $0 }.joined(separator: "  ·  ")).font(.caption).foregroundStyle(.secondary)
			}
			Spacer()
			Button(exists ? "Restore…" : "Restore") {
				if exists { pending.restoreReplacing = b } else { state.restore(b, replace: false) }
			}.controlSize(.small).disabled(!b.restorable || state.task.running).help(b.restorable ? "" : "Database-only backup: use devstack import")
			Button { state.openFolder(b.path) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help("Show in Finder")
			Button { pending.deleting = b } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete this backup")
		}
		.padding(.horizontal, 14).padding(.vertical, 7)
	}
}

// MARK: - Remove

struct RemoveSiteView: View {
	@EnvironmentObject private var state: AppState
	@Environment(\.dismiss) private var dismiss
	let site: Site
	@StateObject private var form = FormModel()
	private var backupFirst: Bool { form.backupFirst }

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			HStack(alignment: .top, spacing: 12) {
				Image(systemName: "trash.circle.fill").font(.system(size: 34)).foregroundStyle(.red)
				VStack(alignment: .leading, spacing: 6) {
					Text(backupFirst ? "Archive “\(site.name)”?" : "Remove “\(site.name)”?").font(.title3.weight(.semibold))
					Text("This unlinks \(site.url), removes its certificate, drops its database and database user, and deletes \(abbreviate(site.path)).")
						.foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
				}
			}
			VStack(alignment: .leading, spacing: 6) {
				Toggle("Back up first (verbatim, restorable from Backups…)", isOn: $form.backupFirst)
				Toggle("Compress the files so the disk space is really freed (minutes for big sites)", isOn: $form.compress)
					.disabled(!backupFirst)
				if let size = site.sizeText { Text("This site uses \(size).").font(.caption).foregroundStyle(.secondary) }
				if backupFirst && !form.compress {
					Text("Without compression the backup is an instant clone that keeps sharing the site's blocks, so removing the site frees only the database.").font(.caption).foregroundStyle(.secondary)
				}
			}
			.padding(.leading, 46)
			HStack {
				Spacer()
				Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
				Button(backupFirst ? (form.compress ? "Compress, back up and remove" : "Back up and remove") : "Remove") { state.remove(site, backupFirst: backupFirst, compress: form.compress) }
					.keyboardShortcut(.defaultAction).tint(.red)
			}
		}
		.padding(20)
		.frame(width: 520)
		.navigationTitle(backupFirst ? "Archive site" : "Remove site")
	}
}

// MARK: - Task log

struct TaskView: View {
	@EnvironmentObject private var state: AppState
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		let t = state.task
		VStack(alignment: .leading, spacing: 10) {
			HStack(spacing: 10) {
				if t.running { ProgressView().controlSize(.small) }
				else { Image(systemName: t.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(t.succeeded ? .green : .red) }
				VStack(alignment: .leading, spacing: 2) {
					Text(t.title).font(.headline)
					Text(t.command).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
				}
				Spacer()
			}
			ScrollViewReader { proxy in
				ScrollView {
					LazyVStack(alignment: .leading, spacing: 1) {
						ForEach(t.lines) { line in
							Text(line.text)
								.font(.system(size: 11, design: .monospaced))
								.foregroundStyle(color(for: line))
								.textSelection(.enabled)
								.frame(maxWidth: .infinity, alignment: .leading)
								.id(line.id)
						}
					}
					.padding(8)
				}
				.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
				.onChange(of: t.lines.count) { _, _ in
					if let last = t.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
				}
			}
			.frame(minHeight: 260)
			if !t.running, let r = t.result { resultCard(r) }
			HStack {
				if !t.running, let s = t.exitStatus {
					Text(s == 0 ? "Finished" : "Failed with status \(s)").font(.callout).foregroundStyle(s == 0 ? Color.secondary : Color.red)
				}
				Spacer()
				if !state.history.isEmpty {
					Menu("Previous tasks") {
						ForEach(state.history) { h in
							Button { state.showHistory(h) } label: {
								Label("\(h.title) — \(h.startedAt.formatted(date: .omitted, time: .shortened))", systemImage: h.succeeded ? "checkmark.circle" : "xmark.circle")
							}
						}
					}
					.fixedSize().disabled(t.running)
				}
				Button("Copy log") { state.copy(t.lines.map(\.text).joined(separator: "\n")) }
				Button(t.running ? "Hide" : "Close") { dismiss() }.keyboardShortcut(.cancelAction)
			}
		}
		.padding(16)
		.frame(width: 620, height: 460)
		.navigationTitle(t.title)
	}

	private func color(for line: Devstack.Line) -> Color {
		let l = line.text.lowercased()
		if l.contains("error") || l.contains("fatal") || l.contains("failed") { return .red }
		if l.contains("warning") { return .orange }
		return line.isError ? .primary : .secondary
	}

	private func resultCard(_ r: JobResult) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			if let url = r.url {
				HStack {
					Text(url).font(.callout.weight(.medium)).textSelection(.enabled)
					Button("Open") { state.open(url) }.controlSize(.small)
					if let name = r.name, r.adminPassword != nil {
						Button("Log in to wp-admin") { Task { await state.login(siteNamed: name) } }.controlSize(.small)
					}
				}
			}
			if let u = r.adminUser, let p = r.adminPassword, !p.isEmpty {
				HStack(spacing: 8) {
					Text("wp-admin").foregroundStyle(.secondary)
					Text(u).font(.callout.monospaced()).textSelection(.enabled)
					Text("/").foregroundStyle(.tertiary)
					Text(p).font(.callout.monospaced()).textSelection(.enabled)
					Button { state.copy(p) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy password")
					Spacer()
				}
				.font(.callout)
			}
			if let p = r.path, r.url == nil {
				HStack {
					Text(abbreviate(p)).font(.callout).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
					Button("Show in Finder") { state.openFolder(p) }.controlSize(.small)
				}
			}
			if let to = r.to {
				HStack(spacing: 8) {
					Text((r.updated ?? false) ? "Updated to \(to.prefix(7))." : "Already up to date (\(to.prefix(7))).").font(.callout)
					if r.appNeedsRestart {
						Text("The app itself changed.").font(.callout).foregroundStyle(.secondary)
						Button("Rebuild and restart DevStack") { state.restartAfterUpdate() }.controlSize(.small)
					}
				}
			}
		}
		.padding(10)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
	}
}
