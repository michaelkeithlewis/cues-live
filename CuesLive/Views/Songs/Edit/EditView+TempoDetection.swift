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
