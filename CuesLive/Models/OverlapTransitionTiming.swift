import Foundation

enum OverlapTransitionTiming {
    static let defaultEditorWindowDuration: TimeInterval = 10
    static let defaultStartOffsetSeconds: TimeInterval = 5

    static func defaultStartOffset(
        windowDuration: TimeInterval,
        outgoingDuration: TimeInterval
    ) -> TimeInterval {
        guard windowDuration > 0 else { return 0 }
        return min(defaultStartOffsetSeconds, windowDuration, outgoingDuration)
    }

    /// Seconds of outgoing audio the editor keeps visible before the incoming song starts.
    static let editorLeadInSeconds: TimeInterval = 2

    /// The overlap can run as long as the outgoing song. The editor widens its window to fit it.
    static func clampedStartOffset(
        _ offset: TimeInterval,
        outgoingDuration: TimeInterval
    ) -> TimeInterval {
        max(0, min(offset, outgoingDuration))
    }

    /// Timeline position on the outgoing song where incoming playback begins.
    static func incomingAlignmentTime(
        outgoingDuration: TimeInterval,
        startOffsetSeconds: TimeInterval
    ) -> TimeInterval {
        max(0, outgoingDuration - startOffsetSeconds)
    }

    /// Offset of the incoming lane in the shared editor window (seconds).
    static func incomingLaneOffset(
        outgoingDuration: TimeInterval,
        windowDuration: TimeInterval,
        startOffsetSeconds: TimeInterval
    ) -> TimeInterval {
        let outgoingWindowStart = max(0, outgoingDuration - windowDuration)
        let alignmentTime = incomingAlignmentTime(
            outgoingDuration: outgoingDuration,
            startOffsetSeconds: startOffsetSeconds
        )
        return max(0, alignmentTime - outgoingWindowStart)
    }
}
