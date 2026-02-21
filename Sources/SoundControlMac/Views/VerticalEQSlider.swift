import SwiftUI

struct VerticalEQSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    private let trackWidth: CGFloat = 4
    private let knobDiameter: CGFloat = 12
    private let stepSize: Double = 0.5

    var body: some View {
        GeometryReader { geometry in
            let metrics = sliderMetrics(in: geometry.size)
            let knobY = yPosition(for: clampedValue(value), metrics: metrics)
            let zeroY = yPosition(for: clampedValue(0), metrics: metrics)

            ZStack {
                Capsule()
                    .fill(Color.secondary.opacity(0.24))
                    .frame(width: trackWidth, height: metrics.trackHeight)
                    .position(x: metrics.centerX, y: metrics.trackCenterY)

                Capsule()
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: trackWidth, height: max(2, abs(knobY - zeroY)))
                    .position(x: metrics.centerX, y: (knobY + zeroY) / 2)

                Circle()
                    .fill(Color.accentColor)
                    .frame(width: knobDiameter, height: knobDiameter)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.7), lineWidth: 1)
                    )
                    .position(x: metrics.centerX, y: knobY)
                    .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)

                if range.lowerBound < 0 && range.upperBound > 0 {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.45))
                        .frame(width: 8, height: 1)
                        .position(x: metrics.centerX, y: zeroY)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        value = value(for: gesture.location.y, metrics: metrics)
                    }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("EQ gain")
        .accessibilityValue(Text("\(clampedValue(value).formatted(.number.precision(.fractionLength(1)))) dB"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                value = clampedValue(value + stepSize)
            case .decrement:
                value = clampedValue(value - stepSize)
            default:
                break
            }
        }
    }

    private func sliderMetrics(in size: CGSize) -> (topY: CGFloat, bottomY: CGFloat, trackHeight: CGFloat, trackCenterY: CGFloat, centerX: CGFloat) {
        let topY = knobDiameter / 2
        let bottomY = max(topY + 1, size.height - knobDiameter / 2)
        let trackHeight = bottomY - topY
        return (
            topY: topY,
            bottomY: bottomY,
            trackHeight: trackHeight,
            trackCenterY: (topY + bottomY) / 2,
            centerX: size.width / 2
        )
    }

    private func yPosition(for value: Double, metrics: (topY: CGFloat, bottomY: CGFloat, trackHeight: CGFloat, trackCenterY: CGFloat, centerX: CGFloat)) -> CGFloat {
        let normalized = normalize(value: value)
        return metrics.bottomY - CGFloat(normalized) * metrics.trackHeight
    }

    private func value(for yPosition: CGFloat, metrics: (topY: CGFloat, bottomY: CGFloat, trackHeight: CGFloat, trackCenterY: CGFloat, centerX: CGFloat)) -> Double {
        let clampedY = min(max(yPosition, metrics.topY), metrics.bottomY)
        let ratio = Double((metrics.bottomY - clampedY) / metrics.trackHeight)
        return clampedValue(range.lowerBound + ratio * (range.upperBound - range.lowerBound))
    }

    private func normalize(value: Double) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return (clampedValue(value) - range.lowerBound) / span
    }

    private func clampedValue(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
