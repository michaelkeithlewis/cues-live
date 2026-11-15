import XCTest
@testable import CuesLive

final class TrackBatchRenameTests: XCTestCase {
    func testStepsRunReplaceTrimAddThenNumber() {
        var rename = TrackBatchRename()
        rename.replaces = true
        rename.find = "_Lord of the Harvest"
        rename.trims = true
        rename.trimEnd = 3
        rename.adds = true
        rename.prefix = "LOTH "
        rename.numbers = true
        rename.startNumber = 1

        XCTAssertEqual(
            rename.rename(["kick in_Lord of the Harvest_42", "sn top_Lord of the Harvest_45"]),
            ["LOTH kick in 1", "LOTH sn top 2"]
        )
    }

    func testReplaceIgnoresCaseUnlessAsked() {
        var rename = TrackBatchRename()
        rename.replaces = true
        rename.find = "vox"
        rename.replacement = "Vocal"

        XCTAssertEqual(rename.rename("VOX Eric", index: 0), "Vocal Eric")

        rename.matchesCase = true
        XCTAssertEqual(rename.rename("VOX Eric", index: 0), "VOX Eric")
    }

    func testNumbersCanLeadWithCustomStepAndSeparator() {
        var rename = TrackBatchRename()
        rename.numbers = true
        rename.startNumber = 10
        rename.increment = 5
        rename.numberPosition = .before
        rename.separator = " - "

        XCTAssertEqual(rename.rename(["Bass", "Keys"]), ["10 - Bass", "15 - Keys"])
    }

    func testAnEmptyResultKeepsTheOldName() {
        var rename = TrackBatchRename()
        rename.trims = true
        rename.trimStart = 10

        XCTAssertEqual(rename.rename("Bass", index: 0), "Bass")
    }
}
