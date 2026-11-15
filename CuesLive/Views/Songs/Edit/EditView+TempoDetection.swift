import SwiftUI

extension EditView {
    /// Sets the song's opening tempo from the audio. Later tempo changes are left alone.
    func detectTempo() {
        guard !isDetectingTempo else { return }
        let urls = SongSectionDetector.analysisTracks(in: song)
            .compactMap { FileStore.trackURL(for: song, track: $0) }
        isDetectingTempo = true

        Task {
            defer { isDetectingTempo = false }
            do {
                let bpm = try await SongTempoDetector.detectBPM(from: urls)
                performUndoableChange("Detect Tempo") {
                    applyDetectedTempo(bpm)
                }
            } catch {
                tempoDetectionError = error.localizedDescription
            }
        }
    }

    /// Takes what the import analysis found for this song while it was open. A tempo or sections
    /// changed by hand in the meantime are kept.
    func adoptBackgroundAnalysis() {
        guard let result = SongImportAnalyzer.shared.takeEditorResult(for: song.id) else { return }
        let openingBPM = normalizedTempoChanges.first(where: \.isOrigin)?.bpm ?? normalizedTempoChanges.referenceBPM
        if let bpm = result.bpm, openingBPM == result.importedBPM {
            performUndoableChange("Detect Tempo") {
                applyDetectedTempo(bpm)
            }
        }
        if let sections = result.sections, timeline.markers.count <= 1 {
            performUndoableChange("Detect Sections") {
                applyDetectedSections(sections)
            }
        }
    }

    private func applyDetectedTempo(_ bpm: Double) {
        var changes = normalizedTempoChanges
        guard let index = changes.firstIndex(where: \.isOrigin) else { return }
        let origin = changes[index]
        changes[index] = TempoChange(
            id: origin.id,
            startMeasure: origin.startMeasure,
            beatOffset: origin.beatOffset,
            bpm: bpm,
            sortOrder: origin.sortOrder
        )
        tempoChanges = changes
        persistTempoChanges()
    }

    var tempoDetectionAlert: Binding<Bool> {
        Binding(
            get: { tempoDetectionError != nil },
            set: { if !$0 { tempoDetectionError = nil } }
        )
    }
}
