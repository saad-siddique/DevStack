// Models.swift — the JSON contract of `devstack status --json` (bin/stack-status) and friends.
import Foundation

struct StackStatus: Decodable {
	var generatedAt: String
	var services: [Service]
	var php: [PhpVersion]
	var sites: [Site]
	var ports: [String: String?]
	var mysql: MySQLInfo
	var mail: MailInfo
	var upgrades: Upgrades?
	var watchdog: Watchdog?
	var sizes: Sizes?

	struct Sizes: Decodable {
		let computedAt: String?
		let filesTotal: Int?
		let dbTotal: Int?
		var computedDate: Date? { computedAt.flatMap { ISO8601DateFormatter().date(from: $0) } }
	}

	/// Everything that is not a php-fpm pool; those live under PHP.
	var coreServices: [Service] { services.filter { !$0.name.hasPrefix("php") } }
	var onlineCount: Int { coreServices.filter(\.isRunning).count }
	var defaultPhp: PhpVersion? { php.first(where: \.isDefault) }
	var userSites: [Site] { sites.filter { $0.name != "dashboard" && $0.name != "phpmyadmin" } }

	var health: Health {
		let core = ["nginx", "dnsmasq", "mysql@8.4"]
		if core.contains(where: { name in !(services.first { $0.name == name }?.isRunning ?? false) }) { return .down }
		if services.contains(where: \.isError) { return .degraded }
		if php.contains(where: { $0.sites > 0 && !$0.fpmRunning }) { return .degraded }
		return .ok
	}

	var summary: String {
		var parts = ["\(onlineCount)/\(coreServices.count) services online", "\(userSites.count) sites"]
		if let d = defaultPhp { parts.append("PHP \(d.version) default") }
		return parts.joined(separator: "  ·  ")
	}

	var portsLine: String {
		ports.keys.compactMap { Int($0) }.sorted().compactMap { port -> String? in
			guard let owner = ports[String(port)] ?? nil else { return nil }
			return "\(port) \(owner)"
		}.joined(separator: "  ·  ")
	}
}

enum Health { case ok, degraded, down, unknown }

struct Service: Decodable, Identifiable, Equatable {
	let name: String
	let status: String
	let user: String?
	var id: String { name }
	var isRunning: Bool { status == "started" }
	var isError: Bool { status == "error" }
	var subtitle: String {
		switch name {
		case "nginx": return "web server, ports 80 and 443"
		case "dnsmasq": return "*.test DNS"
		case "mysql@8.4": return "MySQL 8.4, port 3306"
		case "mailpit": return "mail catcher, SMTP 1025 · UI 8025"
		case "redis": return "object cache, port 6379"
		case "memcached": return "object cache, port 11211"
		default: return status
		}
	}
}

struct PhpVersion: Decodable, Identifiable, Equatable {
	let version: String
	let full: String
	let formula: String
	let fpm: String
	let isDefault: Bool
	let sites: Int
	let xdebug: Bool
	enum CodingKeys: String, CodingKey { case version, full, formula, fpm, sites, xdebug, isDefault = "default" }
	var id: String { version }
	var fpmRunning: Bool { fpm == "started" }
}

struct Site: Decodable, Identifiable, Equatable, Hashable {
	let name: String
	let php: String
	let secured: Bool
	let wp: Bool
	let path: String
	let protected: Bool?
	let fatalsRecent: Int?      // PHP fatals in wp-content/debug.log today or yesterday
	let debugLog: String?
	let db: String?
	let dbBytes: Int?           // live, from information_schema
	let filesBytes: Int?        // from the nightly du (devstack sizes --refresh)
	var totalBytes: Int { (dbBytes ?? 0) + (filesBytes ?? 0) }
	var sizeText: String? {
		guard filesBytes != nil || dbBytes != nil else { return nil }
		var parts: [String] = []
		if let f = filesBytes { parts.append(ByteCountFormatter.string(fromByteCount: Int64(f), countStyle: .file)) }
		if let d = dbBytes, d > 0 { parts.append("\(ByteCountFormatter.string(fromByteCount: Int64(d), countStyle: .file)) db") }
		return parts.joined(separator: " + ")
	}
	var id: String { name }
	var isProtected: Bool { protected ?? false }
	var url: String { "\(secured ? "https" : "http")://\(name).test" }
	var adminUrl: String { url + "/wp-admin/" }
}

struct MySQLInfo: Decodable { let version: String?; let qps: Double? }
struct MailInfo: Decodable { let backend: String?; let total: Int? }

/// What site-new / site-import / site-backup / update print with --json (only the fields the app shows).
struct JobResult: Decodable {
	let name: String?
	let url: String?
	let path: String?
	let adminUser: String?
	let adminPassword: String?
	let ok: Bool?
	// update
	let to: String?
	let updated: Bool?
	let appChanged: Bool?
	let appRebuilt: Bool?
	var appNeedsRestart: Bool { (updated ?? false) && (appChanged ?? false) && !(appRebuilt ?? false) }
}

/// `devstack upgrade` state (bin/stack-upgrade), embedded in status: Homebrew upgrades of the stack itself.
struct Upgrades: Decodable {
	struct Outdated: Decodable, Identifiable {
		let short: String
		let installed: String
		let current: String
		let kind: String          // patch | minor | major
		var id: String { short }
		var line: String { "\(short) \(installed) → \(current)" }
	}
	struct Run: Decodable {
		struct Upgraded: Decodable { let name: String; let from: String; let to: String }
		struct Failed: Decodable { let name: String; let error: String? }
		let at: String?
		let mode: String?
		let upgraded: [Upgraded]?
		let restarted: [String]?
		let failed: [Failed]?
	}
	let checkedAt: String?
	let available: [Outdated]?
	let lastRun: Run?
	let auto: String?         // off | patch | all — what the nightly run may apply unattended

	var autoEnabled: Bool { (auto ?? "off") != "off" }
	var patches: [Outdated] { (available ?? []).filter { $0.kind == "patch" } }
	var review: [Outdated] { (available ?? []).filter { $0.kind != "patch" } }
	/// A run in the last 24 h that changed something (or failed) is worth a line in the panel.
	var recentRun: Run? {
		guard let r = lastRun, let at = r.at, let d = ISO8601DateFormatter().date(from: at), Date().timeIntervalSince(d) < 86_400 else { return nil }
		if (r.upgraded ?? []).isEmpty && (r.failed ?? []).isEmpty { return nil }
		return r
	}
	var hasNews: Bool { !(available ?? []).isEmpty || recentRun != nil }
}

/// `devstack logs crashes --json`: macOS crash (.ips) and resource (.diag) reports for stack processes.
struct Reports: Decodable {
	struct Report: Decodable, Identifiable {
		let process: String
		let time: String?
		let kind: String?       // "crash" or a resource event: "disk writes", "cpu", "wakeups"
		let reason: String?
		let file: String?
		var id: String { file ?? process + (time ?? "") }
		var isCrash: Bool { (kind ?? "crash") == "crash" }
	}
	let hours: Int?
	let count: Int?
	let crashes: Int?
	let resource: Int?
	let reports: [Report]?
	var crashList: [Report] { (reports ?? []).filter(\.isCrash) }
	var resourceList: [Report] { (reports ?? []).filter { !$0.isCrash } }
}

/// `bin/watchdog` state: what the five-minute nginx/dnsmasq check last did.
struct Watchdog: Decodable {
	struct Action: Decodable, Identifiable {
		let service: String
		let statusBefore: String?
		let result: String?
		let at: String?
		var id: String { (at ?? "") + service }
	}
	let lastCheck: String?
	let actions: [Action]?
}

/// One row of `devstack backups --json`.
struct BackupEntry: Decodable, Identifiable, Equatable {
	let name: String
	let created: String?
	let path: String
	let php: String?
	let db: String?
	let tables: Int?
	let dbDump: String?
	let files: Bool?
	let filesArchive: String?
	let sizeBytes: Int?
	var id: String { path }
	var isCompressed: Bool { filesArchive != nil }
	var createdDate: Date? { created.flatMap { ISO8601DateFormatter().date(from: $0) } }
	var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(sizeBytes ?? 0), countStyle: .file) }
	var restorable: Bool { files ?? false }
}

/// `devstack update --check --json`
struct UpdateInfo: Decodable {
	let behind: Int?
	let appChanged: Bool?
	let dirty: Bool?
	let reachable: Bool?
	let commits: [String]?
	var isAvailable: Bool { (behind ?? 0) > 0 }
}
