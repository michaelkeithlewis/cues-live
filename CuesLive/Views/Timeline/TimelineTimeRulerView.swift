import SwiftUI

/// Minutes-and-seconds ruler, pinned at the top of the timeline above the meter lane.
/// Ticks rise from the bottom edge; labeled times sit to the right of a tall tick and shorter
/// ticks fill the gaps.
struct TimelineTimeRulerView: View {
    let duration: TimeInterval
    let contentWidth: CGFloat
    let displayWidth: CGFloat
    let height: CGFloat

    private static let labelTop: CGFloat = 3

    /// Set in the editor. The canvas then covers only the painted slice.
    @Environment(\.timelineScrollModel) private var scrollModel

    private var safeDuration: TimeInterval {
        max(duration, 0.001)
    }

    private var effectiveDisplayWidth: CGFloat {
        max(contentWidth, displayWidth)
    }

    private var pixelsPerSecond: CGFloat {
        contentWidth / CGFloat(safeDuration)
    }

    /// Content x range the canvas occupies: the painted slice of the editor, else everything.
    private var paintedSlice: ClosedRange<CGFloat> {
        guard let painted = scrollModel?.paintedRange else { return 0...effectiveDisplayWidth }
        let lower = max(0, painted.lowerBound)
        let upper = min(effectiveDisplayWidth, painted.upperBound)
        return upper > lower ? lower...upper : 0...0
    }

    var body: some View {
        let slice = paintedSlice
        Canvas { context, size in
            let scale = TimeRulerScale(pixelsPerSecond: pixelsPerSecond)
            let mark = GraphicsContext.Shading.color(AppColors.Timeline.timeRulerTick)
            guard scale.minor > 0, contentWidth > 0 else { return }

            // Ticks are placed in content coordinates; the canvas starts at the slice.
            context.translateBy(x: -slice.lowerBound, y: 0)
            let secondsPerPoint = safeDuration / TimeInterval(contentWidth)
            let lowerTime = max(0, TimeInterval(slice.lowerBound - 60) * secondsPerPoint)
            let upperTime = min(extendedMaximumTime, TimeInterval(slice.upperBound) * secondsPerPoint)
            let subdivisions = max(1, Int((scale.major / scale.minor).rounded()))
            let firstStep = Int((lowerTime / scale.minor).rounded(.down))
            let lastStep = Int((upperTime / scale.minor).rounded(.up))
            guard lastStep >= firstStep else { return }
            let minorTickHeight = min(4, size.height)
            let majorTickHeight = min(max(9, size.height * 0.46), size.height)

            var minorPath = Path()
            var majorPath = Path()
            for step in firstStep...lastStep {
                let x = xPosition(for: Double(step) * scale.minor)
                let isMajor = step % subdivisions == 0
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: size.height))
                tick.addLine(to: CGPoint(x: x, y: size.height - (isMajor ? majorTickHeight : minorTickHeight)))
                if isMajor {
                    majorPath.addPath(tick)
                } else {
                    minorPath.addPath(tick)
                }
            }

            context.stroke(minorPath, with: mark, lineWidth: 1)
            context.stroke(majorPath, with: mark, lineWidth: 1)

            let firstMajor = Int((Double(firstStep) / Double(subdivisions)).rounded(.up)) * subdivisions
            for step in stride(from: firstMajor, through: lastStep, by: subdivisions) {
                let time = Double(step) * scale.minor
                let x = xPosition(for: time)
                guard x <= effectiveDisplayWidth - 8 else { break }
                let label = context.resolve(
                    Text(Self.formatRulerTime(time, fractionDigits: scale.fractionDigits))
                        .font(AppTypography.Compact.timecode)
                        .foregroundStyle(.secondary)
                )
                context.draw(label, at: CGPoint(x: x + 4, y: Self.labelTop), anchor: .topLeading)
            }
        }
        .frame(width: slice.upperBound - slice.lowerBound, height: height, alignment: .topLeading)
        .offset(x: slice.lowerBound)
        .frame(width: effectiveDisplayWidth, height: height, alignment: .topLeading)
        .background(AppColors.Timeline.stickyRulerBackground)
        .allowsHitTesting(false)
    }

    private func xPosition(for time: TimeInterval) -> CGFloat {
        TimelineLayout.xPosition(for: time, duration: safeDuration, contentWidth: contentWidth)
    }

    private var extendedMaximumTime: TimeInterval {
        guard contentWidth > 0, effectiveDisplayWidth > contentWidth else { return safeDuration }
        return safeDuration * TimeInterval(effectiveDisplayWidth / contentWidth)
    }

    private static func formatRulerTime(_ value: TimeInterval, fractionDigits: Int) -> String {
        let clamped = max(0, value)
        let minutes = Int(clamped) / 60
        let seconds = clamped - Double(minutes * 60)
        if fractionDigits > 0 {
            return String(format: "%d:%0*.*f", minutes, fractionDigits + 3, fractionDigits, seconds)
        }
        let wholeSeconds = Int((seconds + 0.000_1).rounded(.down))
        return String(format: "%d:%02d", minutes, wholeSeconds)
    }
}

/// Labeled spacing stays wide enough to read; unlabeled ticks subdivide it.
private struct TimeRulerScale {
    var major: TimeInterval
    var minor: TimeInterval

    init(pixelsPerSecond: CGFloat) {
        let pps = max(pixelsPerSecond, 0.001)
        let majors: [TimeInterval] = [
            0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600
        ]
        let raw = Double(140 / pps)
        major = majors.first(where: { $0 >= raw - 0.000_1 }) ?? 600
        let candidate = Self.preferredMinor(for: major)
        minor = CGFloat(candidate) * pps >= 8 ? candidate : major
    }

    /// Decimal places a label needs to tell neighbouring major ticks apart.
    var fractionDigits: Int {
        if major >= 1 { return 0 }
        if major >= 0.1 { return 1 }
        if major >= 0.01 { return 2 }
        return 3
    }

    private static func preferredMinor(for major: TimeInterval) -> TimeInterval {
        switch major {
        case 0.001: return 0.000_2
        case 0.002: return 0.000_5
        case 0.005: return 0.001
        case 0.01: return 0.002
        case 0.02: return 0.005
        case 0.05: return 0.01
        case 0.1: return 0.02
        case 0.2: return 0.05
        case 0.5: return 0.1
        case 1: return 0.2
        case 2: return 0.5
        case 5: return 1
        case 10: return 2
        case 15: return 5
        case 30: return 5
        case 60: return 10
        case 120: return 30
        case 300: return 60
        default: return 120
        }
    }
}
