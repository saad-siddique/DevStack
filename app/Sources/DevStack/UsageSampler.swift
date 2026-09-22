// UsageSampler.swift — CPU and memory of the stack's own processes from `ps`: every 3 s while the panel is open,
// once a minute while it is closed (that slow tick is what catches a runaway worker in the background).
import Foundation

@MainActor
final class UsageSampler: ObservableObject {
	struct Sample: Identifiable {
		let id = UUID()
		let time: Date
		let cpu: Double          // summed %CPU of stack processes
		let memoryMB: Double     // summed resident memory
		let byProcess: [String: Double]          // %CPU per service (php@8.4, mysql@8.4, nginx, …)
		let memoryByProcess: [String: Double]    // MB per service
	}

	/// A process that has been hot for a while: the service to restart and how long it has been at it.
	struct Runaway: Identifiable, Equatable {
		let service: String
		let cpu: Double
		let memoryMB: Double
		let since: Date
		var id: String { service }
	}

	@Published private(set) var samples: [Sample] = []
	@Published private(set) var runaways: [Runaway] = []
	nonisolated static let processes: Set<String> = ["php-fpm", "nginx", "mysqld", "redis-server", "memcached", "mailpit", "dnsmasq"]
	private let capacity = 60
	private var interval: Double = 60
	private var loop: Task<Void, Never>?
	private var hotSince: [String: Date] = [:]
	static let hotCPU = 120.0          // summed %CPU of one service (a php-fpm pool counts as one)
	static let hotSeconds = 90.0       // for this long, continuously
	static let hotMemoryMB = 3072.0    // or this much resident memory

	var isRunning: Bool { loop != nil }

	func start(interval: Double) {
		if loop != nil && interval == self.interval { return }
		self.interval = interval
		loop?.cancel()
		loop = Task { [weak self] in
			while !Task.isCancelled {
				if let s = await Self.sample() { self?.append(s) }
				guard let self else { return }
				try? await Task.sleep(for: .seconds(self.interval))
			}
		}
	}

	func stop() {
		loop?.cancel()
		loop = nil
	}

	private func append(_ s: Sample) {
		samples.append(s)
		if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
		// Runaway bookkeeping: a service counts once it has been over the CPU line for hotSeconds, or over the memory line at all.
		var found: [Runaway] = []
		for (key, cpu) in s.byProcess {
			let mem = s.memoryByProcess[key] ?? 0
			if cpu >= Self.hotCPU {
				let since = hotSince[key] ?? s.time
				hotSince[key] = since
				if s.time.timeIntervalSince(since) >= Self.hotSeconds || mem >= Self.hotMemoryMB { found.append(Runaway(service: key, cpu: cpu, memoryMB: mem, since: since)) }
			} else {
				hotSince[key] = nil
				if mem >= Self.hotMemoryMB { found.append(Runaway(service: key, cpu: cpu, memoryMB: mem, since: s.time)) }
			}
		}
		let sorted = found.sorted { $0.service < $1.service }
		if sorted != runaways { runaways = sorted }
	}

	/// ps prints the full path; map it to the service name bin/service understands.
	nonisolated static func serviceKey(for command: String) -> String? {
		let name = (command as NSString).lastPathComponent
		switch name {
		case "mysqld": return "mysql@8.4"
		case "redis-server": return "redis"
		case "memcached", "mailpit", "nginx", "dnsmasq": return name
		default:
			guard name.hasPrefix("php-fpm") else { return nil }
			if let r = command.range(of: #"php@[0-9]+\.[0-9]+"#, options: .regularExpression) { return String(command[r]) }
			if let r = command.range(of: #"/php/([0-9]+\.[0-9]+)"#, options: .regularExpression) {   // Homebrew's `php` formula (8.5)
				let v = command[r].split(separator: "/").last.map(String.init) ?? ""
				return "php@\(v)"
			}
			return "php-fpm"
		}
	}

	nonisolated static func sample() async -> Sample? {
		let p = Process()
		p.executableURL = URL(fileURLWithPath: "/bin/ps")
		p.arguments = ["-axo", "pcpu=,rss=,comm="]
		let pipe = Pipe()
		p.standardOutput = pipe
		p.standardError = FileHandle.nullDevice
		do { try p.run() } catch { return nil }
		let data = await Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }.value
		await Task.detached { p.waitUntilExit() }.value

		var cpu = 0.0, rss = 0.0
		var by: [String: Double] = [:], mem: [String: Double] = [:]
		for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
			let parts = line.split(separator: " ", omittingEmptySubsequences: true)
			guard parts.count >= 3, let c = Double(parts[0]), let r = Double(parts[1]) else { continue }
			let command = parts[2...].joined(separator: " ")
			guard let key = serviceKey(for: command) else { continue }
			cpu += c
			rss += r
			by[key, default: 0] += c
			mem[key, default: 0] += r / 1024
		}
		return Sample(time: Date(), cpu: cpu, memoryMB: rss / 1024, byProcess: by, memoryByProcess: mem)
	}
}
