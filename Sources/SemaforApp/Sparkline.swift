import SwiftUI

/// Minimal sparkline: strokes a normalized series (values are
/// "× segment median", so ~1.0 is the normal band) without any charting
/// dependencies (spec §9).
struct Sparkline: Shape {
    var values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count >= 2,
              let low = values.min(), let high = values.max()
        else { return path }
        let span = max(high - low, 0.001)
        let stepX = rect.width / CGFloat(values.count - 1)
        for (index, value) in values.enumerated() {
            let x = rect.minX + CGFloat(index) * stepX
            let fraction = CGFloat((value - low) / span)
            let y = rect.maxY - fraction * rect.height
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}

/// 60×18 pair used in the popover rows.
struct SparklinePair: View {
    let ttft: [Double]
    let tokPerSec: [Double]

    var body: some View {
        HStack(spacing: 8) {
            spark(ttft, caption: "ttft")
            spark(tokPerSec, caption: "tok/s")
        }
    }

    @ViewBuilder
    private func spark(_ values: [Double], caption: String) -> some View {
        if values.count >= 2 {
            VStack(spacing: 1) {
                Sparkline(values: values)
                    .stroke(lineWidth: 1)
                    .frame(width: 60, height: 18)
                    .padding(2)
                    .tint(.secondary)
                Text(caption)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
