// UsageSampler.swift — CPU and memory of the stack's own processes, sampled from `ps` only while the panel is open.
import Foundation

@MainActor
final class UsageSampler: ObservableObject {
	struct Sample: Identifiable {
		let id = UUID()
		let time: Date
		let cpu: Double          // summed %CPU of stack processes
		let memoryMB: Double     // summed resident memory
		let byProcess: [String: Double]
	}

	@Published private(set) var samples: [Sample] = []
	nonisolated static let processes: Set<String> = ["php-fpm", "nginx", "mysqld", "redis-server", "memcached", "mailpit", "dnsmasq"]
	private let capacity = 60          // 60 samples × 3 s = the last three minutes
	private var loop: Task<Void, Never>?

	var isRunning: Bool { loop != nil }

	func start() {
		guard loop == nil else { return }
		loop = Task { [weak self] in
			while !Task.isCancelled {
				if let s = await Self.sample() { self?.append(s) }
				try? await Task.sleep(for: .seconds(3))
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
		var by: [String: Double] = [:]
		for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
			let parts = line.split(separator: " ", omittingEmptySubsequences: true)
			guard parts.count >= 3, let c = Double(parts[0]), let r = Double(parts[1]) else { continue }
			let name = (parts[2...].joined(separator: " ") as NSString).lastPathComponent
			let key = name.hasPrefix("php-fpm") ? "php-fpm" : name
			guard processes.contains(key) else { continue }
			cpu += c
			rss += r
			by[key, default: 0] += c
		}
		return Sample(time: Date(), cpu: cpu, memoryMB: rss / 1024, byProcess: by)
	}
}
