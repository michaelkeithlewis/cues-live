import XCTest
@testable import CuesLive

final class SongTempoDetectorTests: XCTestCase {
    func testClickAndGuideStemsAreLeftOutOfTheMix() {
        let urls = ["Drums.wav", "Bass.wav", "Click.wav", "Guide.wav"].map { URL(fileURLWithPath: "/song/\($0)") }

        XCTAssertEqual(SongTempoDetector.analysisURLs(fromStems: urls).map(\.lastPathComponent), ["Drums.wav", "Bass.wav"])
    }

    func testClickIsUsedWhenItIsTheOnlyAudio() {
        let urls = [URL(fileURLWithPath: "/song/Click.wav")]

        XCTAssertEqual(SongTempoDetector.analysisURLs(fromStems: urls).map(\.lastPathComponent), ["Click.wav"])
    }

    func testGuideStemsAreLeftOutOfTheMix() {
        let urls = ["Drums.wav", "Guide Vox.wav", "Keys.wav"].map { URL(fileURLWithPath: "/song/\($0)") }

        XCTAssertEqual(
            SongTempoDetector.analysisURLs(fromStems: urls).map(\.lastPathComponent),
            ["Drums.wav", "Keys.wav"]
        )
    }

    func testNearWholeTempoSnapsToWholeNumber() {
        XCTAssertEqual(SongTempoDetector.normalizedBPM(71.86), 72)
        XCTAssertEqual(SongTempoDetector.normalizedBPM(120.14), 120)
    }

    func testFractionalTempoKeepsOneDecimal() {
        XCTAssertEqual(SongTempoDetector.normalizedBPM(87.46), 87.5)
    }

    func testOutOfRangeTempoIsRejected() {
        XCTAssertNil(SongTempoDetector.normalizedBPM(5))
        XCTAssertNil(SongTempoDetector.normalizedBPM(.nan))
    }

    func testTempoFromBeatTimesUsesMedianGap() {
        let beats: [TimeInterval] = [0, 0.5, 1.0, 1.5, 2.3, 2.5, 3.0]

        XCTAssertEqual(SongTempoDetector.bpm(fromBeatTimes: beats) ?? 0, 120, accuracy: 0.001)
    }

    func testTooFewBeatsGiveNoTempo() {
        XCTAssertNil(SongTempoDetector.bpm(fromBeatTimes: [0, 0.5, 1.0]))
    }
}
