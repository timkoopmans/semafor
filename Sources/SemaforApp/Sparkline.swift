import SwiftUI

import SemaforCore

/// Minimal sparkline on a **fixed 0…2 domain**: values are "× segment
/// median", so 1.0 (the dashed median line, dead centre) means "usual".
/// Auto-scaling was the whole problem — any series filled the frame and
/// nothing read as fast or slow (spec §9).
struct Sparkline: Shape {
    var values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count >= 2 else { return path }
        let stepX = rect.width / CGFloat(values.count - 1)
        for (index, value) in values.enumerated() {
            let x = rect.minX + CGFloat(index) * stepX
            let fraction = CGFloat(min(max(value, 0), 2) / 2)
            let y = rect.maxY - fraction * rect.height
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}

/// The "usual" reference: a dashed line at normalized 1.0 (half the 0…2 domain).
struct MedianRule: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let y = rect.maxY - rect.height / 2
        path.move(to: CGPoint(x: rect.minX, y: y))
        path.addLine(to: CGPoint(x: rect.maxX, y: y))
        return path
    }
}

/// Value + "usual" caption + fixed-domain squiggle for one metric.
struct MetricTileView: View {
    let tile: MetricTileModel
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(tile.valueText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(SemaforApp.color(for: tile.color))
            Text(tile.usualText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            ZStack {
                Sparkline(values: tile.series)
                    .stroke(lineWidth: 1)
                MedianRule()
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
            .tint(.secondary)
            .frame(width: 60, height: 18)
            Text(caption)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
    }
}
