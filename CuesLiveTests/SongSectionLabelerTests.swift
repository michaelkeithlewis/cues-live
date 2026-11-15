import XCTest
@testable import CuesLive

final class SongSectionLabelerTests: XCTestCase {
    /// Twenty-second sections; sections of the same part sound alike, every other pair does not.
    private func song(_ parts: [(part: String, sung: Bool, loudness: Double)]) -> ([SectionProfile], [[Float]]) {
        let profiles = parts.enumerated().map { index, part in
            SectionProfile(
                start: Double(index) * 20,
                end: Double(index + 1) * 20,
                vocalCoverage: part.sung ? 0.9 : 0,
                loudness: part.loudness
            )
        }
        let similarity = parts.map { a in parts.map { b in a.part == b.part ? Float(0.8) : 0.1 } }
        return (profiles, similarity)
    }

    func testCommonPopFormIsNamed() {
        let (profiles, similarity) = song([
            ("intro", false, -12), ("verse", true, -10), ("chorus", true, -6), ("verse", true, -10),
            ("chorus", true, -6), ("bridge", true, -8), ("chorus", true, -5), ("outro", false, -12),
        ])

        let labels = SongSectionLabeler.label(profiles, audioSimilarity: similarity)

        XCTAssertEqual(labels?.map(\.name), [
            "Intro", "Verse 1", "Chorus 1", "Verse 2", "Chorus 2", "Bridge", "Chorus 3", "Outro",
        ])
    }

    func testPartThatAlwaysLeadsIntoTheChorusIsPreChorus() {
        let (profiles, similarity) = song([
            ("intro", false, -12), ("verse", true, -10), ("pre", true, -8), ("chorus", true, -5),
            ("verse", true, -10), ("pre", true, -8), ("chorus", true, -5), ("bridge", true, -8),
            ("chorus", true, -5), ("outro", false, -12),
        ])

        let labels = SongSectionLabeler.label(profiles, audioSimilarity: similarity)

        XCTAssertEqual(labels?.map(\.name), [
            "Intro", "Verse 1", "Pre-Chorus 1", "Chorus 1", "Verse 2", "Pre-Chorus 2", "Chorus 2",
            "Bridge", "Chorus 3", "Outro",
        ])
    }

    func testSplitChorusIsMergedIntoOneSection() {
        let (profiles, similarity) = song([
            ("intro", false, -12), ("verse", true, -10), ("chorus", true, -6), ("chorus", true, -6),
            ("verse", true, -10), ("chorus", true, -6), ("outro", false, -12),
        ])

        let labels = SongSectionLabeler.label(profiles, audioSimilarity: similarity)

        XCTAssertEqual(labels?.map(\.name), ["Intro", "Verse 1", "Chorus 1", "Verse 2", "Chorus 2", "Outro"])
        XCTAssertEqual(labels?.map(\.start), [0, 20, 40, 80, 100, 120])
    }

    func testSongWithNothingSungIsLeftUnnamed() {
        let (profiles, similarity) = song([("a", false, -10), ("b", false, -10)])

        XCTAssertNil(SongSectionLabeler.label(profiles, audioSimilarity: similarity))
    }

    func testLyricSimilarityCountsSharedWordPairs() {
        let first = ["i", "want", "you", "to", "live", "forever"]
        let second = ["i", "want", "you", "to", "fill", "your", "lungs"]

        XCTAssertEqual(SongSectionLabeler.lyricSimilarity(first, second), 0.6, accuracy: 0.001)
        XCTAssertEqual(SongSectionLabeler.lyricSimilarity(["oh", "oh"], ["oh", "oh"]), 0)
    }
}
