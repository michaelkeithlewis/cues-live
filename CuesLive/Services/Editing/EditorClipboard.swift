import Foundation
import Observation

/// What Copy put on the song editor's clipboard. It lasts for the app session and pastes only into
/// the song it came from, because clips play their own track's audio file.
@Observable
final class EditorClipboard {
    static let shared = EditorClipboard()

    enum Content {
        /// Clips on their own tracks, timed from the first one. Paste lays them over the edit point.
        case clips([TrackClip], length: TimeInterval)
        /// A stretch of the whole song. Paste inserts it at a bar line and pushes the rest right.
        case span(SongSpan)
    }

    private(set) var songID: UUID?
    private(set) var content: Content?

    func store(_ content: Content, from songID: UUID) {
        self.songID = songID
        self.content = content
    }

    func content(for songID: UUID) -> Content? {
        self.songID == songID ? content : nil
    }
}
