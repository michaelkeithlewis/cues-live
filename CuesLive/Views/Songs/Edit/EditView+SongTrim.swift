import SwiftUI

/// Whole-song trims for tightening a song's head or tail before a transition. Both cut at the bar
/// line nearest the edit point, across every track, section marker, and MIDI lane.
extension EditView {
    /// Bar line nearest the edit point: the range start while a selection shows, otherwise the insertion.
    private var trimBoundary: (measure: Int, time: TimeInterval) {
        MeasureTiming.nearestMeasureBoundary(
            to: playbackStart,
            tempoChanges: normalizedTempoChanges,
            timeSignatureChanges: normalizedTimeSignatureChanges
        )
    }

    var canTrimSongStart: Bool {
        trimBoundary.measure > 1 && trimBoundary.time < timelineDuration - ClipEditing.tolerance
    }

    var canTrimSongEnd: Bool {
        let time = trimBoundary.time
        return time > ClipEditing.tolerance && time < timeline.duration - ClipEditing.tolerance
    }

    /// Removes every bar before the edit point and slides the rest of the song to the top.
    /// Tempo and meter changes move with the bars they belong to.
    func trimSongStart() {
        guard canTrimSongStart else { return }
        let measure = trimBoundary.measure
        clearMarkerCue()
        clipSelection.deselectAll()
        editSelection = nil
        performUndoableChange("Trim Song Start") {
            var tempo = normalizedTempoChanges
            var meter = normalizedTimeSignatureChanges
            TimelineRippleStore.rippleDeleteMeasures(
                startMeasure: 1,
                endMeasure: measure,
                timeline: &timeline,
                tempoChanges: &tempo,
                timeSignatureChanges: &meter,
                midiEvents: &midiEvents,
                defaultBPM: song.bpm ?? TempoChange.defaultBPM,
                defaultNumerator: song.timeSignatureNumerator ?? MeasureTiming.defaultNumerator,
                defaultDenominator: song.timeSignatureDenominator ?? MeasureTiming.defaultDenominator
            )
            tempoChanges = tempo
            timeSignatureChanges = meter
            applyWholeSongTrim()
        }
        insertionTime = 0
    }

    /// Removes everything from the edit point to the end of the song.
    func trimSongEnd() {
        guard canTrimSongEnd else { return }
        let time = trimBoundary.time
        clearMarkerCue()
        clipSelection.deselectAll()
        editSelection = nil
        performUndoableChange("Trim Song End") {
            ClipEditing.deleteRange(
                trackIDs: Set(timeline.clips.map(\.trackID)),
                from: time,
                to: timeline.duration + 1,
                in: &timeline.clips
            )
            timeline.markers.removeAll { $0.startSeconds >= time - ClipEditing.tolerance }
            midiEvents.removeAll { $0.timelineSeconds >= time - ClipEditing.tolerance }
            applyWholeSongTrim()
        }
        insertionTime = min(insertionTime, time)
    }

    private func applyWholeSongTrim() {
        persistProjectState()
        syncPlayback()
        viewModel.syncTempoMap(normalizedTempoChanges, timeSignatureChanges: normalizedTimeSignatureChanges)
        reconfigureMIDI()
        prepareSectionAnnouncements()
    }
}
