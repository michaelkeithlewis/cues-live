import Foundation

/// Hands the live engine to the song editor while that song is loaded, so opening and closing
/// the editor does not interrupt playback. Live view creates one per editor visit; the editor
/// records anything that leaves the engine unusable for live playback as it was.
final class LiveEditorHandoff {
    let songID: UUID
    /// The editor loaded the engine itself, for example after a track change.
    var editorReloadedEngine = false
    /// The editor moved on to a different song from its library.
    var editorSwitchedSong = false

    init(songID: UUID) {
        self.songID = songID
    }

    /// True while the engine still holds exactly what live playback loaded.
    var isEngineIntact: Bool {
        !editorReloadedEngine && !editorSwitchedSong
    }
}
