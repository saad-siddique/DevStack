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
	var id: String { name }
	var isProtected: Bool { protected ?? false }
	var url: String { "\(secured ? "https" : "http")://\(name).test" }
	var adminUrl: String { url + "/wp-admin/" }
}

struct MySQLInfo: Decodable { let version: String?; let qps: Double? }
struct MailInfo: Decodable { let backend: String?; let total: Int? }

/// What site-new / site-import / site-backup print with --json (only the fields the app shows).
struct JobResult: Decodable {
	let url: String?
	let path: String?
	let adminUser: String?
	let adminPassword: String?
	let ok: Bool?
}
