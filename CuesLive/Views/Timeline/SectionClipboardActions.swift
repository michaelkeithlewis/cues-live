import Foundation

/// Copy, cut and paste for whole sections, offered from the section ruler's menu.
struct SectionClipboardActions {
    var canPaste = false
    var copy: (SongSection) -> Void = { _ in }
    var cut: (SongSection) -> Void = { _ in }
    var pasteBefore: (SongSection) -> Void = { _ in }
}
