// Components.swift — small shared views: status dot, the load chart, an inline error line.
import Charts
import SwiftUI

struct StatusDot: View {
	@Environment(\.colorScheme) private var scheme
	enum Kind { case on, off, error, busy }
	let kind: Kind
	var body: some View {
		let t = Theme(scheme)
		let color: Color = { switch kind { case .on: return t.ok; case .off: return t.off; case .error: return t.bad; case .busy: return .clear } }()
		Group {
			if kind == .busy {
				ProgressView().controlSize(.mini)
			} else {
				Circle().fill(color).frame(width: 8, height: 8)
					.shadow(color: t.glow && kind == .on ? color.opacity(0.75) : .clear, radius: 4)
			}
		}
		.frame(width: 26, height: 26)
	}
}

struct ErrorLine: View {
	let message: String
	let dismiss: () -> Void
	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 6) {
			Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
			Text(message).font(.caption).lineLimit(3).textSelection(.enabled)
			Spacer(minLength: 0)
			Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless).controlSize(.small)
		}
		.notice(.red)
	}
}

/// "Update available" with the commit count and one button; the update itself always runs in the task window.
struct UpdateLine: View {
	let info: UpdateInfo
	let update: () -> Void
	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 6) {
			Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
			VStack(alignment: .leading, spacing: 1) {
				Text("Update available: \(info.behind ?? 0) commit\((info.behind ?? 0) == 1 ? "" : "s")\((info.appChanged ?? false) ? ", app changed" : "")")
					.font(.caption.weight(.medium))
				if let first = info.commits?.first {
					Text(first.replacingOccurrences(of: #"^[0-9a-f]+ "#, with: "", options: .regularExpression)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
				}
				if info.dirty ?? false {
					Text("Local changes in the repo will block the pull.").font(.caption2).foregroundStyle(.orange)
				}
			}
			Spacer(minLength: 6)
			Button("Update", action: update).controlSize(.small)
		}
		.notice(Color.accentColor)
	}
}

/// Homebrew state of the stack: what the nightly run changed, what waits for review, one Upgrade button.
struct StackUpgradeLine: View {
	let upgrades: Upgrades
	let upgradeAll: () -> Void
	let upgradePatches: () -> Void

	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 6) {
			Image(systemName: symbol).foregroundStyle(color)
			VStack(alignment: .leading, spacing: 1) {
				if let run = upgrades.recentRun {
					let up = (run.upgraded ?? []).map { "\($0.name) \($0.from) → \($0.to)" }
					if !up.isEmpty {
						Text("Upgraded \(when(run.at)): \(up.joined(separator: ", "))").font(.caption.weight(.medium)).lineLimit(2)
					}
					if let f = run.failed, !f.isEmpty {
						Text("Failed: \(f.map(\.name).joined(separator: ", ")) — see devstack logs upgrade").font(.caption2).foregroundStyle(.red)
					}
				}
				if !upgrades.review.isEmpty {
					Text("\(upgrades.review.count) upgrade\(upgrades.review.count == 1 ? "" : "s") to review: \(upgrades.review.map(\.line).joined(separator: ", "))")
						.font(.caption.weight(upgrades.recentRun == nil ? .medium : .regular)).lineLimit(2)
				}
				if !upgrades.patches.isEmpty {
					Text("\(upgrades.patches.count) patch release\(upgrades.patches.count == 1 ? "" : "s") \(upgrades.autoEnabled ? "apply tonight" : "available"): \(upgrades.patches.map(\.line).joined(separator: ", "))")
						.font(upgrades.review.isEmpty && upgrades.recentRun == nil ? .caption.weight(.medium) : .caption2)
						.foregroundStyle(upgrades.review.isEmpty && upgrades.recentRun == nil ? .primary : .secondary).lineLimit(2)
				}
			}
			Spacer(minLength: 6)
			if !upgrades.review.isEmpty {
				Button("Upgrade all", action: upgradeAll).controlSize(.small).help("brew upgrade every outdated stack formula, then restart what changed")
			} else if !upgrades.patches.isEmpty {
				Button("Upgrade", action: upgradePatches).controlSize(.small).help("brew upgrade the patch releases, then restart what changed")
			}
		}
		.notice(color)
	}

	private var symbol: String {
		if let f = upgrades.recentRun?.failed, !f.isEmpty { return "exclamationmark.triangle.fill" }
		return upgrades.review.isEmpty ? "checkmark.shield.fill" : "shippingbox.fill"
	}
	private var color: Color {
		if let f = upgrades.recentRun?.failed, !f.isEmpty { return .orange }
		return upgrades.review.isEmpty ? .green : Color.accentColor
	}
	private func when(_ iso: String?) -> String {
		guard let iso, let d = ISO8601DateFormatter().date(from: iso) else { return "recently" }
		return Calendar.current.isDateInToday(d) ? "today at \(d.formatted(date: .omitted, time: .shortened))" : "yesterday"
	}
}

/// Crash and resource reports macOS wrote for stack processes in the last 24 hours.
struct ReportsLine: View {
	let reports: [Reports.Report]
	let open: (Reports.Report) -> Void
	let dismiss: () -> Void

	var body: some View {
		let crashes = reports.filter(\.isCrash), resource = reports.filter { !$0.isCrash }
		HStack(alignment: .firstTextBaseline, spacing: 6) {
			Image(systemName: crashes.isEmpty ? "gauge.with.dots.needle.67percent" : "bolt.trianglebadge.exclamationmark.fill").foregroundStyle(crashes.isEmpty ? Color.orange : Color.red)
			VStack(alignment: .leading, spacing: 1) {
				if !crashes.isEmpty {
					Text("\(crashes.count) crash\(crashes.count == 1 ? "" : "es") in 24 h: \(Array(Set(crashes.map(\.process))).sorted().joined(separator: ", "))").font(.caption.weight(.medium))
				}
				if !resource.isEmpty {
					Text("macOS flagged \(Array(Set(resource.map { "\($0.process) (\($0.kind ?? "resource"))" })).sorted().joined(separator: ", ")) — a runaway request or job?")
						.font(crashes.isEmpty ? .caption.weight(.medium) : .caption2).lineLimit(2)
				}
			}
			Spacer(minLength: 6)
			if let first = reports.first { Button("Open") { open(first) }.controlSize(.small).help("Open the newest report in Console") }
			Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless).controlSize(.small).help("Hide until new reports appear")
		}
		.notice(crashes.isEmpty ? Color.orange : Color.red)
	}
}

/// A stack process hot for more than a minute (or holding gigabytes): name it and offer the restart.
struct RunawayLine: View {
	let runaways: [UsageSampler.Runaway]
	let restart: (String) -> Void
	let busy: (String) -> Bool

	var body: some View {
		VStack(spacing: 6) {
			ForEach(runaways) { r in
				HStack(alignment: .firstTextBaseline, spacing: 6) {
					Image(systemName: "flame.fill").foregroundStyle(Color.orange)
					VStack(alignment: .leading, spacing: 1) {
						Text("\(r.service) at \(Int(r.cpu))% CPU, \(Int(r.memoryMB)) MB").font(.caption.weight(.medium))
						Text(r.memoryMB >= UsageSampler.hotMemoryMB ? "Holding more than \(Int(UsageSampler.hotMemoryMB / 1024)) GB of memory." : "Hot for \(Int(Date().timeIntervalSince(r.since))) s. A stuck request or an endless loop? Restarting drops in-flight requests.")
							.font(.caption2).foregroundStyle(.secondary).lineLimit(2)
					}
					Spacer(minLength: 6)
					Button(busy(r.service) ? "Restarting…" : "Restart") { restart(r.service) }.controlSize(.small).disabled(busy(r.service))
				}
			}
		}
		.notice(Color.orange)
	}
}

/// A public tunnel is up: where, for which sites, and the way to stop it.
struct ShareLine: View {
	let share: StackStatus.Share
	let copy: (String) -> Void
	let open: (String) -> Void
	let stop: () -> Void
	let busy: Bool

	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 6) {
			Image(systemName: "globe").foregroundStyle(Color.accentColor)
			VStack(alignment: .leading, spacing: 1) {
				Text("Sharing \((share.sites ?? [share.site ?? ""]).joined(separator: ", ")) publicly (\(share.mode ?? "tunnel") tunnel)").font(.caption.weight(.medium))
				ForEach(share.urls ?? [share.url ?? ""], id: \.self) { u in
					HStack(spacing: 4) {
						Text(u).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
						Button { copy(u) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).controlSize(.mini).help("Copy URL")
						Button { open(u) } label: { Image(systemName: "arrow.up.right.square") }.buttonStyle(.borderless).controlSize(.mini).help("Open")
					}
				}
			}
			Spacer(minLength: 6)
			Button(busy ? "Stopping…" : "Stop", action: stop).controlSize(.small).disabled(busy)
		}
		.notice(Color.accentColor)
	}
}

/// Summed CPU of php-fpm, nginx, mysqld, redis, memcached, mailpit and dnsmasq over the last three minutes.
struct UsageChart: View {
	@Environment(\.colorScheme) private var scheme
	@ObservedObject var sampler: UsageSampler

	var body: some View {
		let t = Theme(scheme)
		VStack(alignment: .leading, spacing: 4) {
			HStack(alignment: .firstTextBaseline) {
				Text("Stack load, last \(sampler.samples.count > 30 ? "hour" : "minutes")").font(.caption).foregroundStyle(t.muted)
				Spacer()
				if let s = sampler.samples.last, !s.byProcess.isEmpty {
					Text(s.byProcess.sorted { $0.value > $1.value }.prefix(2).map { "\($0.key) \(String(format: "%.0f", $0.value))%" }.joined(separator: "  ·  "))
						.font(.caption2).monospacedDigit().foregroundStyle(t.faint).lineLimit(1)
				} else {
					Text("sampling…").font(.caption2).foregroundStyle(t.faint)
				}
			}
			Chart(sampler.samples) { s in
				AreaMark(x: .value("Time", s.time), y: .value("CPU", s.cpu))
					.interpolationMethod(.monotone)
					.foregroundStyle(.linearGradient(colors: [t.accent.opacity(t.dark ? 0.30 : 0.22), .clear], startPoint: .top, endPoint: .bottom))
				LineMark(x: .value("Time", s.time), y: .value("CPU", s.cpu))
					.interpolationMethod(.monotone)
					.lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
					.foregroundStyle(t.accent)
			}
			.chartXAxis(.hidden)
			.chartYAxis {
				AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) {
					AxisGridLine().foregroundStyle(t.divider)
					AxisValueLabel().font(.system(size: 9, design: .rounded)).foregroundStyle(t.faint)
				}
			}
			.chartYScale(domain: 0 ... max(5, (sampler.samples.map(\.cpu).max() ?? 0) * 1.25))
			.frame(height: 48)
		}
	}
}

/// A row in the panel lists: a 26-pt tile or dot, title/subtitle, trailing controls; hairline below.
struct Row<Leading: View, Trailing: View>: View {
	@Environment(\.colorScheme) private var scheme
	let title: String
	let subtitle: String
	var star: Bool = false
	@ViewBuilder var leading: Leading
	@ViewBuilder var trailing: Trailing

	var body: some View {
		let t = Theme(scheme)
		HStack(spacing: 10) {
			leading
			VStack(alignment: .leading, spacing: 1) {
				HStack(spacing: 5) {
					Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(t.text).lineLimit(1)
					if star { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(t.warn) }
				}
				Text(subtitle).font(.system(size: 11)).foregroundStyle(t.muted).lineLimit(1)
			}
			Spacer(minLength: 6)
			trailing
		}
		.padding(.horizontal, 12).padding(.vertical, 8)
		.overlay(alignment: .bottom) { Rectangle().fill(t.divider).frame(height: 1).padding(.leading, 48) }
	}
}

/// Right-aligned rounded numerals: a big figure with a small caption under it (sizes, counts).
struct Figure: View {
	@Environment(\.colorScheme) private var scheme
	let value: String
	var caption: String? = nil
	var body: some View {
		let t = Theme(scheme)
		VStack(alignment: .trailing, spacing: 0) {
			Text(value).font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundStyle(t.text.opacity(0.85)).monospacedDigit()
			if let caption { Text(caption).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(t.faint) }
		}
	}
}
