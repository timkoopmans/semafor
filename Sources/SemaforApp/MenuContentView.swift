import SwiftUI

import SemaforCore

/// The popover: one section per provider (bars, countdowns, pace tags,
/// burn-rate headline, error hints) over a footer with manual controls.
struct MenuContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.sections.isEmpty {
                Text("Loading…")
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
            if let divergence = model.divergenceText {
                Label(divergence, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(10)
                Divider()
            }
            ForEach(Array(model.sections.enumerated()), id: \.offset) { index, section in
                if index > 0 { Divider() }
                sectionView(section)
            }
            Divider()
            footer
        }
        .frame(width: 320)
        .task { model.startPolling() }
    }

    private func sectionView(_ section: ProviderSectionModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(section.glyph)
                Text(section.displayName).font(.headline)
                Spacer(minLength: 4)
                if let chip = section.verdictChip {
                    Text(chip)
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background {
                            Capsule().fill(SemaforApp.color(for: section.chipColor).opacity(0.18))
                        }
                        .overlay {
                            Capsule().stroke(SemaforApp.color(for: section.chipColor).opacity(0.6),
                                             lineWidth: 1)
                        }
                        .foregroundStyle(SemaforApp.color(for: section.chipColor))
                }
                SparklinePair(ttft: section.sparkTTFT, tokPerSec: section.sparkTokPerSec)
            }
            if let headline = section.headline {
                Text(headline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                rowView(row)
            }
            if !section.statusLine.isEmpty {
                Text(section.statusLine)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let measured = section.measuredText {
                Text(measured)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
    }

    private func rowView(_ row: ProviderSectionModel.WindowRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(row.label).font(.callout)
                Spacer(minLength: 4)
                if let pace = row.paceText {
                    Text(pace).font(.caption2).foregroundStyle(.orange)
                }
                Text(row.percentText).font(.callout.monospacedDigit())
            }
            if let bar = row.barPercent {
                ProgressView(value: min(max(bar, 0), 100), total: 100)
                    .controlSize(.small)
            }
            Text(row.resetsText).font(.caption2).foregroundStyle(.secondary)
        }
        .opacity(row.dimmed ? 0.35 : 1)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(model.lastPollText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Test now") { model.refreshAll() }
            Button(model.paused ? "Resume" : "Pause") { model.togglePaused() }
            Button {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "settings")
            } label: {
                Image(systemName: "gearshape")
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(10)
    }
}
