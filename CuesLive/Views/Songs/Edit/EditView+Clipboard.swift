import SwiftUI

/// Cut, copy and paste in the song editor. Clips paste over whatever sits at the edit point.
/// Sections paste as a whole-song span: every track, marker and MIDI event, pushing the rest right.
extension EditView {
    private var clipboard: EditorClipboard { .shared }

    private var rangeSelection: ClipRangeDrag? {
        guard let selection = editSelection, selection.end - selection.start > ClipEditing.tolerance else {
            return nil
        }
        return selection
    }

    var canCopyClips: Bool {
        rangeSelection != nil || !clipSelection.isEmpty
    }

    var canPasteClipboard: Bool {
        clipboard.content(for: song.id) != nil
    }

    /// A range copies what lies inside it on its tracks. Without one, the selected clips are copied.
    func copyClips() {
        if let range = rangeSelection {
            var tracksInRange = timeline
            tracksInRange.clips.removeAll { !selectedTrackIDs.contains($0.trackID) }
            tracksInRange.markers = []
            guard let copied = ClipEditing.extractSpan(
                from: range.start,
                to: range.end,
                timeline: tracksInRange,
                midiEvents: []
            ) else { return }
            clipboard.store(.clips(copied.span.clips, length: copied.span.length), from: song.id)
            return
        }

        let selected = timeline.clips.filter { clipSelection.contains($0.id) }
        guard let start = selected.map(\.timelineStartSeconds).min(),
              let end = selected.map(\.timelineEndSeconds).max() else { return }
        let clips = selected.map { clip in
            var copy = clip
            copy.timelineStartSeconds -= start
            return copy
        }
        clipboard.store(.clips(clips, length: end - start), from: song.id)
    }

    func cutClips() {
        guard canCopyClips else { return }
        copyClips()
        if let range = rangeSelection {
            let trackIDs = selectedTrackIDs
            commitTimelineEdit("Cut") { timeline in
                ClipEditing.deleteRange(trackIDs: trackIDs, from: range.start, to: range.end, in: &timeline.clips)
            }
            clipSelection.deselectAll()
        } else {
            removeClipSelection()
        }
    }

    func pasteClipboard() {
        switch clipboard.content(for: song.id) {
        case .clips(let clips, let length):
            pasteClips(clips, length: length, at: playbackStart)
        case .span(let span):
            let bar = MeasureTiming.nearestMeasureBoundary(
                to: playbackStart,
                tempoChanges: normalizedTempoChanges,
                timeSignatureChanges: normalizedTimeSignatureChanges
            )
            pasteSpan(span, at: bar.time)
        case nil:
            break
        }
    }

    private func pasteClips(_ clips: [TrackClip], length: TimeInterval, at destination: TimeInterval) {
        let trackIDs = Set(song.sortedTracks.map(\.id))
        let placed = clips.filter { trackIDs.contains($0.trackID) }.map { clip in
            TrackClip(
                trackID: clip.trackID,
                timelineStartSeconds: destination + clip.timelineStartSeconds,
                duration: clip.duration,
                sourceStartSeconds: clip.sourceStartSeconds,
                gainDB: clip.gainDB,
                playbackRate: clip.playbackRate
            )
        }
        guard !placed.isEmpty else { return }
        commitTimelineEdit("Paste") { timeline in
            ClipEditing.place(placed, in: &timeline.clips)
        }
        editSelection = nil
        clipSelection = ClipSelection(placed.map(\.id))
        // The next paste lands right after this one.
        insertionTime = destination + length
    }

    private func pasteSpan(_ span: SongSpan, at destination: TimeInterval) {
        clearMarkerCue()
        clipSelection.deselectAll()
        editSelection = nil
        performUndoableChange("Paste Section") {
            ClipEditing.insertSpan(span, at: destination, timeline: &timeline, midiEvents: &midiEvents)
            persistProjectState()
            syncPlayback()
            reconfigureMIDI()
            prepareSectionAnnouncements()
        }
        insertionTime = destination + span.length
    }

    private func copySection(_ section: SongSection) {
        guard let copied = ClipEditing.extractSpan(
            from: section.timelineStartSeconds,
            to: section.timelineEndSeconds,
            copyLoops: true,
            timeline: timeline,
            midiEvents: midiEvents
        ) else { return }
        clipboard.store(.span(copied.span), from: song.id)
    }

    var sectionClipboardActions: SectionClipboardActions {
        SectionClipboardActions(
            canPaste: canPasteClipboard,
            copy: copySection,
            cut: { section in
                copySection(section)
                deleteSection(section)
            },
            pasteBefore: { section in
                switch clipboard.content(for: song.id) {
                case .span(let span):
                    pasteSpan(span, at: section.timelineStartSeconds)
                case .clips(let clips, let length):
                    pasteClips(clips, length: length, at: section.timelineStartSeconds)
                case nil:
                    break
                }
            }
        )
    }
}
