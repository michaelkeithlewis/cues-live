import SwiftUI

/// Typing over the timeline: the text filters the song's sections, and Return goes to the highlighted
/// one or adds a section with the typed name. Keys stay with the timeline, so the first letter typed
/// is never lost to a field taking focus.
struct MarkerQuickFind: Equatable {
    enum Choice: Hashable {
        case section(SongSection)
        case add(String)
    }

    enum Outcome {
        case handled
        case ignored
        case dismiss
        case choose(Choice)
    }

    var text: String
    var highlighted = 0

    /// Opens on a plain letter or digit, the way type-to-select works in a list.
    static func opening(with press: KeyPress) -> MarkerQuickFind? {
        guard press.modifiers.isSubset(of: [.shift]),
              press.characters.count == 1,
              let character = press.characters.first,
              character.isLetter || character.isNumber else { return nil }
        return MarkerQuickFind(text: press.characters)
    }

    /// Matches first, then adding the typed name unless a section already has exactly that name.
    func choices(in sections: [SongSection]) -> [Choice] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = query.isEmpty ? sections : sections.filter { $0.name.localizedCaseInsensitiveContains(query) }
        var choices = matches.map(Choice.section)
        let name = SongSectionNameNormalizer.canonicalize(query)
        if !name.isEmpty, !sections.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            choices.append(.add(name))
        }
        return choices
    }

    func highlightedIndex(in sections: [SongSection]) -> Int {
        min(max(0, highlighted), max(0, choices(in: sections).count - 1))
    }

    mutating func handle(_ press: KeyPress, sections: [SongSection]) -> Outcome {
        let choices = choices(in: sections)
        switch press.key {
        case .escape:
            return .dismiss
        case .return:
            guard !choices.isEmpty else { return .dismiss }
            return .choose(choices[highlightedIndex(in: sections)])
        case .upArrow, .downArrow:
            guard !choices.isEmpty else { return .handled }
            let step = press.key == .upArrow ? -1 : 1
            highlighted = (highlightedIndex(in: sections) + step + choices.count) % choices.count
            return .handled
        case .delete:
            guard !text.isEmpty else { return .dismiss }
            text.removeLast()
            highlighted = 0
            return text.isEmpty ? .dismiss : .handled
        default:
            guard press.modifiers.isSubset(of: [.shift]), !press.characters.isEmpty,
                  press.characters.allSatisfy({ !$0.isNewline && ($0.isLetter || $0.isNumber || $0.isPunctuation || $0 == " ") })
            else { return .ignored }
            text += press.characters
            highlighted = 0
            return .handled
        }
    }
}
