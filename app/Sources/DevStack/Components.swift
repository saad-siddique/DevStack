// Components.swift — small shared views: status dot, the load chart, an inline error line.
import Charts
import SwiftUI

struct StatusDot: View {
	enum Kind { case on, off, error, busy }
	let kind: Kind
	var body: some View {
		Group {
			if kind == .busy {
				ProgressView().controlSize(.mini)
			} else {
				Circle().fill(color).frame(width: 8, height: 8)
			}
		}
		.frame(width: 12, height: 12)
	}
	private var color: Color {
		switch kind {
		case .on: return .green
		case .off: return Color(nsColor: .tertiaryLabelColor)
		case .error: return .red
		case .busy: return .clear
		}
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
		.padding(.horizontal, 10).padding(.vertical, 6)
		.background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
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
		.padding(.horizontal, 10).padding(.vertical, 6)
		.background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
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
		.padding(.horizontal, 10).padding(.vertical, 6)
		.background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
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

/// Summed CPU of php-fpm, nginx, mysqld, redis, memcached, mailpit and dnsmasq over the last three minutes.
struct UsageChart: View {
	@ObservedObject var sampler: UsageSampler

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(alignment: .firstTextBaseline) {
				Text("Stack load").font(.caption).foregroundStyle(.secondary)
				Spacer()
				if let s = sampler.samples.last {
					Text("CPU \(s.cpu, specifier: "%.1f")%   ·   \(Int(s.memoryMB)) MB")
						.font(.caption).monospacedDigit().foregroundStyle(.secondary)
				} else {
					Text("sampling…").font(.caption).foregroundStyle(.tertiary)
				}
			}
			Chart(sampler.samples) { s in
				AreaMark(x: .value("Time", s.time), y: .value("CPU", s.cpu))
					.interpolationMethod(.monotone)
					.foregroundStyle(.linearGradient(colors: [Color.accentColor.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
				LineMark(x: .value("Time", s.time), y: .value("CPU", s.cpu))
					.interpolationMethod(.monotone)
					.lineStyle(StrokeStyle(lineWidth: 1.5))
					.foregroundStyle(Color.accentColor)
			}
			.chartXAxis(.hidden)
			.chartYAxis {
				AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) {
					AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
					AxisValueLabel().font(.caption2).foregroundStyle(.tertiary)
				}
			}
			.chartYScale(domain: 0 ... max(5, (sampler.samples.map(\.cpu).max() ?? 0) * 1.25))
			.frame(height: 56)
			if let s = sampler.samples.last, !s.byProcess.isEmpty {
				Text(s.byProcess.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key) \(String(format: "%.1f", $0.value))%" }.joined(separator: "   "))
					.font(.caption2).monospacedDigit().foregroundStyle(.tertiary).lineLimit(1)
			}
		}
	}
}

/// A row in the panel lists: fixed left indicator, title/subtitle, trailing controls.
struct Row<Leading: View, Trailing: View>: View {
	let title: String
	let subtitle: String
	@ViewBuilder var leading: Leading
	@ViewBuilder var trailing: Trailing

	var body: some View {
		HStack(spacing: 10) {
			leading
			VStack(alignment: .leading, spacing: 1) {
				Text(title).lineLimit(1)
				Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
			}
			Spacer(minLength: 6)
			trailing
		}
		.padding(.horizontal, 14).padding(.vertical, 6)
	}
}
