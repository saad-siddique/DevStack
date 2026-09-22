// Snapshot.swift — `DevStack --snapshot <dir>` renders the panel and each form into PNGs and quits.
// Used by `devstack app snapshot` for the README and for checking the UI without clicking through the menu bar.
// It shows fixture sites (never the machine's real ones) and captures the app's own windows, which needs no
// screen-recording permission.
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
		state.freeze(with: fixture)
		try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		state.sampler.start(interval: 3)
		try? await Task.sleep(for: .seconds(7))          // a few load samples so the chart has a line
		await capture(PanelView().environmentObject(state), "panel", dir)
		state.setUpdate(UpdateInfo(behind: 3, appChanged: true, dirty: false, reachable: true,
		                           commits: ["a1b2c3d Import: accept .sql.gz dumps", "b2c3d4e App: Xdebug switch per PHP version", "c3d4e5f README: LocalWP export steps"]))
		await capture(PanelView().environmentObject(state), "panel-update", dir)
		state.setUpdate(nil)
		var withUpgrades = fixture
		withUpgrades.upgrades = try? Devstack.decoder.decode(Upgrades.self, from: Data("""
		{"checked_at":"2026-09-22T03:31:00Z","available":[{"short":"redis","installed":"8.10.2","current":"8.12.0","kind":"minor"}],
		 "last_run":{"at":"\(ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600 * 5)))","mode":"auto",
		 "upgraded":[{"name":"php@8.4","from":"8.4.25","to":"8.4.26"},{"name":"mailpit","from":"1.27.0","to":"1.27.1"}],"restarted":["php@8.4","mailpit"],"failed":[]},"auto":"patch"}
		""".utf8))
		state.freeze(with: withUpgrades)
		await capture(PanelView().environmentObject(state), "panel-upgrades", dir)
		state.freeze(with: fixture)
		state.setBackups([
			BackupEntry(name: "acme-shop", created: "2026-09-22T03:12:00Z", path: "\(NSHomeDirectory())/Backups/DevStack/acme-shop/20260922-031200", php: "php@8.4", db: "wp_acme_shop", tables: 43, dbDump: "db.sql.gz", files: true, filesArchive: nil, sizeBytes: 277_618_688),
			BackupEntry(name: "acme-shop", created: "2026-09-21T03:12:00Z", path: "\(NSHomeDirectory())/Backups/DevStack/acme-shop/20260921-031200", php: "php@8.4", db: "wp_acme_shop", tables: 43, dbDump: "db.sql.gz", files: true, filesArchive: nil, sizeBytes: 271_000_000),
			BackupEntry(name: "old-landing", created: "2026-09-18T17:40:00Z", path: "\(NSHomeDirectory())/Backups/DevStack/old-landing/20260918-174000", php: "php@7.4", db: "wp_old_landing", tables: 12, dbDump: "db.sql.gz", files: true, filesArchive: "files.tar.zst", sizeBytes: 31_000_000),
		])
		state.modal = .backups(nil)
		await capture(ModalView().environmentObject(state), "backups", dir)
		state.modal = .newSite
		await capture(ModalView().environmentObject(state), "new-site", dir)
		state.modal = .importSite
		await capture(ModalView().environmentObject(state), "import", dir)
		if let site = state.status?.userSites.first(where: { !$0.isProtected }) {
			state.modal = .remove(site)
			await capture(ModalView().environmentObject(state), "remove", dir)
		}
		state.task = TaskLog(title: "Back up acme-shop", command: "devstack backup acme-shop --json",
		                     lines: ["12:28:36 === site-backup acme-shop -> ~/Backups/DevStack/acme-shop/20260922-122836",
		                             "12:28:37 db: dumping wp_acme_shop (43 tables)", "12:28:37 db: 332K compressed",
		                             "12:28:39 files: cloned 10546 files", "12:28:39 done: ~/Backups/DevStack/acme-shop/20260922-122836 (264M on disk)"]
		                        .map { Devstack.Line(isError: true, text: $0) },
		                     running: false, exitStatus: 0,
		                     result: JobResult(name: "acme-shop", url: nil, path: NSHomeDirectory() + "/Backups/DevStack/acme-shop/20260922-122836", adminUser: nil, adminPassword: nil, ok: true, to: nil, updated: nil, appChanged: nil, appRebuilt: nil))
		state.modal = .task
		await capture(ModalView().environmentObject(state), "task", dir)
		print("snapshots written to \(dir)")
		NSApp.terminate(nil)
	}

	/// Made-up sites so screenshots never show a real machine's inventory.
	private static var fixture: StackStatus {
		let home = NSHomeDirectory()
		func site(_ n: String, _ php: String, wp: Bool = true, protected: Bool = false, files: Int = 900_000_000, db: Int = 60_000_000) -> Site {
			Site(name: n, php: php, secured: true, wp: wp, path: "\(home)/Sites/\(n)", protected: protected, fatalsRecent: n == "client-blog" ? 2 : 0,
			     debugLog: wp ? "\(home)/Sites/\(n)/wp-content/debug.log" : nil, db: wp ? "wp_\(n.replacingOccurrences(of: "-", with: "_"))" : nil,
			     dbBytes: wp ? db : nil, filesBytes: files)
		}
		func svc(_ n: String, _ u: String) -> Service { Service(name: n, status: "started", user: u) }
		func php(_ v: String, _ full: String, fpm: Bool, def: Bool = false, sites: Int = 0) -> PhpVersion {
			PhpVersion(version: v, full: full, formula: v == "8.5" ? "php" : "php@\(v)", fpm: fpm ? "started" : "none", isDefault: def, sites: sites, xdebug: false)
		}
		return StackStatus(
			generatedAt: "2026-09-22T12:00:00Z",
			services: [svc("dnsmasq", "root"), svc("mailpit", "dev"), svc("memcached", "dev"), svc("mysql@8.4", "dev"), svc("nginx", "root"), svc("redis", "dev"),
			           svc("php@7.4", "root"), svc("php@8.2", "root"), svc("php@8.4", "root")],
			php: [php("7.4", "7.4.33", fpm: true, sites: 2), php("8.0", "8.0.30", fpm: false), php("8.1", "8.1.33", fpm: false),
			      php("8.2", "8.2.29", fpm: true, sites: 1), php("8.3", "8.3.26", fpm: false), php("8.4", "8.4.13", fpm: true, def: true, sites: 4),
			      php("8.5", "8.5.2", fpm: false), php("8.6", "8.6.0", fpm: false)],
			sites: [site("acme-shop", "default", files: 2_400_000_000, db: 410_000_000), site("client-blog", "8.2", files: 650_000_000, db: 38_000_000),
			        site("company-docs", "7.4", files: 1_100_000_000, db: 120_000_000), site("landing-page", "default", wp: false, files: 45_000_000),
			        site("legacy-intranet", "7.4", files: 7_800_000_000, db: 1_600_000_000), site("plugin-dev", "default", protected: true, files: 13_300_000_000, db: 1_570_000_000),
			        site("staging-mirror", "default", files: 6_200_000_000, db: 1_800_000_000)],
			ports: ["80": "nginx", "443": "nginx", "3306": "mysql", "1025": "mailpit", "8025": "mailpit", "6379": "redis", "11211": "memcached"],
			mysql: MySQLInfo(version: "8.4.6", qps: 0.4),
			mail: MailInfo(backend: "mailpit", total: 3),
			upgrades: nil, watchdog: nil,
			sizes: StackStatus.Sizes(computedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600 * 10)), filesTotal: 32_500_000_000, dbTotal: 5_538_000_000))
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
