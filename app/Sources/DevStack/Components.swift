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
