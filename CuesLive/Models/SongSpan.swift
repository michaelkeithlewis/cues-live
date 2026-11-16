import Foundation

/// A copied stretch of a song across every track: clips, section markers, and MIDI events,
/// all timed from the start of the span.
struct SongSpan {
    var length: TimeInterval
    var clips: [TrackClip]
    var markers: [ArrangementMarker]
    var midiEvents: [MIDIEvent]
}
