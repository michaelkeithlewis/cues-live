import XCTest
@testable import CuesLive

final class SongGuideCueReaderTests: XCTestCase {
    private typealias Cue = SongGuideCueReader.SpokenCue

    /// Two-second bars from 0, as at 120 BPM in 4/4.
    private let bars = stride(from: 0.0, through: 400, by: 2.0).map { $0 }

    func testSectionWordsBeatDynamicCalls() {
        XCTAssertEqual(SongGuideCueReader.sectionName(for: "Chorus one, breakdown."), "Chorus")
        XCTAssertEqual(SongGuideCueReader.sectionName(for: "Pre chorus. Build."), "Pre-Chorus")
        XCTAssertEqual(SongGuideCueReader.sectionName(for: "Hits. Vamp."), "Vamp")
        XCTAssertNil(SongGuideCueReader.sectionName(for: "Drums."))
        XCTAssertNil(SongGuideCueReader.sectionName(for: "All in."))
    }

    func testSectionStartsAtTheBarAfterItsCall() {
        let cues = [
            Cue(start: 5.9, end: 7.0, text: "Verse one."),
            Cue(start: 37.8, end: 38.8, text: "Pre chorus."),
            Cue(start: 53.9, end: 55.3, text: "Chorus one, breakdown.")
        ]

        let markers = SongGuideCueReader.markers(from: cues, measureStarts: bars, songDuration: 300)

        XCTAssertEqual(markers.map(\.name), ["Verse", "Pre-Chorus", "Chorus"])
        XCTAssertEqual(markers.map(\.startSeconds), [0, 40, 56])
    }

    func testCallsBeforeTheFirstSectionBelongToIt() {
        let cues = [
            Cue(start: 0.1, end: 4.1, text: "One, two, vamp, two, three, four."),
            Cue(start: 5.9, end: 7.0, text: "Verse one.")
        ]

        let markers = SongGuideCueReader.markers(from: cues, measureStarts: bars, songDuration: 300)

        XCTAssertEqual(markers.map(\.name), ["Vamp", "Verse"])
        XCTAssertEqual(markers.map(\.startSeconds), [0, 8])
    }

    func testRepeatedCallsMergeAndReturningPartsAreNumbered() {
        let cues = [
            Cue(start: 5.9, end: 7.0, text: "Verse one."),
            Cue(start: 21.0, end: 22.0, text: "Chorus."),
            Cue(start: 37.0, end: 38.0, text: "Chorus."),
            Cue(start: 53.0, end: 54.0, text: "Verse two."),
            Cue(start: 69.0, end: 70.0, text: "Chorus, all in."),
            Cue(start: 85.0, end: 86.0, text: "Bridge, softly."),
            Cue(start: 101.0, end: 102.0, text: "Bridge."),
            Cue(start: 117.0, end: 118.0, text: "Ending.")
        ]

        let markers = SongGuideCueReader.markers(from: cues, measureStarts: bars, songDuration: 300)

        XCTAssertEqual(markers.map(\.name), ["Verse 1", "Chorus 1", "Verse 2", "Chorus 2", "Bridge", "Ending"])
        XCTAssertEqual(markers.map(\.startSeconds), [0, 22, 54, 70, 86, 118])
    }

    func testSentencesSplitOneResultIntoSeparateCalls() {
        let runs = [
            OnDeviceTranscriber.TimedText(start: 84.8, end: 85.3, text: "Break. "),
            OnDeviceTranscriber.TimedText(start: 85.6, end: 86.4, text: "Interlude. "),
            OnDeviceTranscriber.TimedText(start: 86.9, end: 87.7, text: "All in.")
        ]

        let cues = SongGuideCueReader.sentences(from: runs)

        XCTAssertEqual(cues.map(\.text), ["Break. ", "Interlude. ", "All in."])
        XCTAssertEqual(cues.map(\.end), [85.3, 86.4, 87.7])
    }
}
