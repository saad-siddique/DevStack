// Runner.swift — the only way the app touches the stack: it runs `devstack …` (bin/devstack via its
// /opt/homebrew/bin symlink) and reads stdout/stderr. No brew, valet or mysql calls live in the app.
import Foundation

enum Devstack {
	/// bootstrap links bin/devstack into Homebrew's bin: /opt/homebrew on Apple Silicon, /usr/local on Intel.
	static let binary: String = ["/opt/homebrew/bin/devstack", "/usr/local/bin/devstack"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/devstack"
	static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: binary) }

	struct Result {
		let status: Int32
		let stdout: String
		let stderr: String
		var lastErrorLine: String {
			stderr.split(separator: "\n").map { $0.replacingOccurrences(of: #"^\d\d:\d\d:\d\d "#, with: "", options: .regularExpression) }
				.last(where: { !$0.isEmpty }) ?? "devstack exited with status \(status)"
		}
	}

	struct Line: Identifiable, Sendable {
		let id = UUID()
		let isError: Bool
		let text: String
	}

	enum Failure: LocalizedError {
		case notInstalled
		case failed(String)
		var errorDescription: String? {
			switch self {
			case .notInstalled: return "devstack is not installed. Run bootstrap.sh in the DevStack repo."
			case .failed(let m): return m
			}
		}
	}

	// A GUI app starts with a bare environment; the scripts need brew on PATH and HOME for ~/.config/valet.
	private static func makeProcess(_ args: [String]) -> Process {
		let p = Process()
		p.executableURL = URL(fileURLWithPath: binary)
		p.arguments = args
		var env = ProcessInfo.processInfo.environment
		env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
		env["TERM"] = "dumb"
		env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
		env["NO_COLOR"] = "1"
		env["DEVSTACK_FROM_APP"] = "1"        // bin/update: leave the app rebuild to us, we relaunch ourselves
		p.environment = env
		p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
		return p
	}

	/// Run to completion, capturing both streams.
	static func run(_ args: [String]) async -> Result {
		guard isInstalled else { return Result(status: 127, stdout: "", stderr: Failure.notInstalled.localizedDescription) }
		let p = makeProcess(args)
		let out = Pipe(), err = Pipe()
		p.standardOutput = out
		p.standardError = err
		do { try p.run() } catch { return Result(status: 127, stdout: "", stderr: "cannot start devstack: \(error.localizedDescription)") }
		let o = Task.detached { out.fileHandleForReading.readDataToEndOfFile() }
		let e = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }
		let outData = await o.value, errData = await e.value
		await Task.detached { p.waitUntilExit() }.value
		return Result(status: p.terminationStatus, stdout: String(decoding: outData, as: UTF8.self), stderr: String(decoding: errData, as: UTF8.self))
	}

	/// Run a `--json` command and decode its stdout.
	static func runJSON<T: Decodable>(_ type: T.Type, _ args: [String]) async throws -> T {
		let r = await run(args)
		guard r.status == 0 else { throw Failure.failed(r.lastErrorLine) }
		return try decoder.decode(T.self, from: Data(r.stdout.utf8))
	}

	static let decoder: JSONDecoder = {
		let d = JSONDecoder()
		d.keyDecodingStrategy = .convertFromSnakeCase
		return d
	}()

	/// Run and deliver every line as it arrives (from either stream). Returns the exit status.
	static func stream(_ args: [String], onLine: @escaping @Sendable (Line) -> Void) async -> Int32 {
		guard isInstalled else { onLine(Line(isError: true, text: Failure.notInstalled.localizedDescription)); return 127 }
		let p = makeProcess(args)
		let out = Pipe(), err = Pipe()
		p.standardOutput = out
		p.standardError = err
		do { try p.run() } catch {
			onLine(Line(isError: true, text: "cannot start devstack: \(error.localizedDescription)"))
			return 127
		}
		let t1 = Task.detached {
			do { for try await l in out.fileHandleForReading.bytes.lines { onLine(Line(isError: false, text: l)) } } catch {}
		}
		let t2 = Task.detached {
			do { for try await l in err.fileHandleForReading.bytes.lines { onLine(Line(isError: true, text: l)) } } catch {}
		}
		await t1.value
		await t2.value
		await Task.detached { p.waitUntilExit() }.value
		return p.terminationStatus
	}
}
