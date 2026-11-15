import Foundation

/// Renames several tracks at once, the way Pro Tools' Batch Track Rename does: each enabled step
/// runs in order, Replace, then Trim, then Add, then Numbering.
struct TrackBatchRename: Equatable {
    enum NumberPosition: String, CaseIterable, Identifiable {
        case before = "Before"
        case after = "After"

        var id: String { rawValue }
    }

    var replaces = false
    var find = ""
    var replacement = ""
    var matchesCase = false

    var trims = false
    var trimStart = 0
    var trimEnd = 0

    var adds = false
    var prefix = ""
    var suffix = ""

    var numbers = false
    var startNumber = 1
    var increment = 1
    var numberPosition: NumberPosition = .after
    var separator = " "

    /// The new name for the track at `index` among the tracks being renamed. Falls back to the old
    /// name when the steps would leave it empty.
    func rename(_ name: String, index: Int) -> String {
        var result = name
        if replaces, !find.isEmpty {
            result = result.replacingOccurrences(
                of: find,
                with: replacement,
                options: matchesCase ? [] : [.caseInsensitive]
            )
        }
        if trims {
            result = String(result.dropFirst(max(0, trimStart)).dropLast(max(0, trimEnd)))
        }
        if adds {
            result = prefix + result + suffix
        }
        if numbers {
            let number = String(startNumber + index * increment)
            result = numberPosition == .before ? number + separator + result : result + separator + number
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? name : trimmed
    }

    func rename(_ names: [String]) -> [String] {
        names.enumerated().map { rename($0.element, index: $0.offset) }
    }
}
