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
}

struct NewSiteView: View {
	@EnvironmentObject private var state: AppState
	@Environment(\.dismiss) private var dismiss
	@StateObject private var form = FormModel()
	private var name: String { form.name }
	private var php: String { form.php }
	private var empty: Bool { form.empty }

	private var taken: Bool { state.status?.sites.contains { $0.name == name } ?? false }
	private var canCreate: Bool { isValidName(name) && !taken && !php.isEmpty }

	var body: some View {
		Form {
			TextField("Name", text: $form.name, prompt: Text("myplugin"))
			LabeledContent("Address") {
				Text(name.isEmpty ? "https://<name>.test" : "https://\(name).test").foregroundStyle(.secondary).textSelection(.enabled)
			}
			PhpPicker(selection: $form.php)
			Toggle("Empty folder only (no WordPress download)", isOn: $form.empty)
			if taken {
				Text("A site called “\(name)” already exists.").foregroundStyle(.red).font(.callout)
			} else if !name.isEmpty && !isValidName(name) {
				Text("Lowercase letters, digits and dashes only.").foregroundStyle(.red).font(.callout)
			} else {
				Text(empty ? "Creates ~/Sites/\(name.isEmpty ? "<name>" : name) with a placeholder index.php, links and secures it."
				           : "Downloads WordPress, creates its database and user, installs it and secures it. The admin password is shown once, at the end.")
					.foregroundStyle(.secondary).font(.callout)
			}
		}
		.formStyle(.grouped)
		.safeAreaInset(edge: .bottom) {
			FormFooter(cancel: { dismiss() }, action: "Create site", enabled: canCreate) { state.createSite(name: name, php: php, empty: empty) }
		}
		.frame(width: 480, height: 320)
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
					Text("Remove “\(site.name)”?").font(.title3.weight(.semibold))
					Text("This unlinks \(site.url), removes its certificate, drops its database and database user, and deletes \(abbreviate(site.path)).")
						.foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
				}
			}
			Toggle("Back up first (files clone + database dump in ~/Backups/local-devstack)", isOn: $form.backupFirst)
				.padding(.leading, 46)
			HStack {
				Spacer()
				Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
				Button(backupFirst ? "Back up and remove" : "Remove") { state.remove(site, backupFirst: backupFirst) }
					.keyboardShortcut(.defaultAction).tint(.red)
			}
		}
		.padding(20)
		.frame(width: 500)
		.navigationTitle("Remove site")
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
					if r.adminPassword != nil { Button("Open wp-admin") { state.open(url + "/wp-admin/") }.controlSize(.small) }
				}
			}
			if let u = r.adminUser, let p = r.adminPassword, !p.isEmpty {
				HStack(spacing: 8) {
					Text("wp-admin login").foregroundStyle(.secondary)
					Text(u).font(.callout.monospaced()).textSelection(.enabled)
					Text("/").foregroundStyle(.tertiary)
					Text(p).font(.callout.monospaced()).textSelection(.enabled)
					Button { state.copy(p) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy password")
					Spacer()
					Text("shown once").font(.caption).foregroundStyle(.tertiary)
				}
				.font(.callout)
			}
			if let p = r.path, r.url == nil {
				HStack {
					Text(abbreviate(p)).font(.callout).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
					Button("Show in Finder") { state.openFolder(p) }.controlSize(.small)
				}
			}
		}
		.padding(10)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
	}
}
