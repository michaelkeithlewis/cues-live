import Foundation
import Observation
import SwiftData

/// Detects the tempo of newly imported songs one at a time in the background, so imports
/// finish straight away and the songs can be edited while their tempo is worked out.
///
/// A result only replaces the opening tempo the song was imported with. If that tempo has been
/// changed by hand in the meantime, the result is dropped. An editor showing the song applies the
/// result itself so its own copy of the tempo map stays current.
@MainActor
@Observable
final class SongTempoAutoDetector {
    static let shared = SongTempoAutoDetector()

    private struct Job {
        let songID: UUID
        let importedBPM: Double
    }

    /// Songs waiting for or undergoing detection, for showing progress in the library.
    private(set) var pendingSongIDs: Set<UUID> = []
    /// Results for songs open in an editor, waiting for that editor to apply them.
    private(set) var editorResults: [UUID: Double] = [:]

    private var queue: [Job] = []
    private var editingSongIDs: Set<UUID> = []
    private var importedBPMs: [UUID: Double] = [:]
    private var worker: Task<Void, Never>?
    private var modelContext: ModelContext?

    private init() {}

    func enqueue(_ songs: [Song], context: ModelContext) {
        guard SongTempoDetector.isAvailable else { return }
        modelContext = context
        for song in songs where !pendingSongIDs.contains(song.id) {
            let job = Job(songID: song.id, importedBPM: song.bpm ?? TempoChange.defaultBPM)
            queue.append(job)
            pendingSongIDs.insert(song.id)
        }
        startWorkerIfNeeded()
    }

    func beginEditing(_ songID: UUID) {
        editingSongIDs.insert(songID)
    }

    /// Writes a result the editor never got to apply straight to the song.
    func endEditing(_ songID: UUID) {
        editingSongIDs.remove(songID)
        if let bpm = editorResults.removeValue(forKey: songID),
           let importedBPM = importedBPMs.removeValue(forKey: songID) {
            applyToStoredSong(songID, bpm: bpm, importedBPM: importedBPM)
        }
    }

    /// Hands an editor's result over, once. Returns nil when the opening tempo was edited by hand.
    func takeEditorResult(for songID: UUID, currentOpeningBPM: Double) -> Double? {
        guard let bpm = editorResults.removeValue(forKey: songID),
              let importedBPM = importedBPMs.removeValue(forKey: songID),
              currentOpeningBPM == importedBPM else { return nil }
        return bpm
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, let job = self.nextJob() {
                await self.run(job)
            }
            self?.worker = nil
        }
    }

    private func nextJob() -> Job? {
        queue.isEmpty ? nil : queue.removeFirst()
    }

    private func run(_ job: Job) async {
        defer { pendingSongIDs.remove(job.songID) }
        guard let song = song(for: job.songID) else { return }
        let urls = SongTempoDetector.analysisURLs(
            fromStems: song.sortedTracks.compactMap { FileStore.trackURL(for: song, track: $0) }
        )
        guard let bpm = try? await SongTempoDetector.detectBPM(from: urls), bpm != job.importedBPM else { return }

        if editingSongIDs.contains(job.songID) {
            importedBPMs[job.songID] = job.importedBPM
            editorResults[job.songID] = bpm
        } else {
            applyToStoredSong(job.songID, bpm: bpm, importedBPM: job.importedBPM)
        }
    }

    private func applyToStoredSong(_ songID: UUID, bpm: Double, importedBPM: Double) {
        guard let modelContext, let song = song(for: songID) else { return }
        let state = SongProjectBridge.projectStateOrDefaults(for: song)
        let tempo = state.tempoChanges.normalizedEnsuringInitialMarker(defaultBPM: song.bpm ?? importedBPM)
        guard let originIndex = tempo.firstIndex(where: \.isOrigin), tempo[originIndex].bpm == importedBPM else { return }

        var updated = tempo
        let origin = updated[originIndex]
        updated[originIndex] = TempoChange(
            id: origin.id,
            startMeasure: origin.startMeasure,
            beatOffset: origin.beatOffset,
            bpm: bpm,
            sortOrder: origin.sortOrder
        )
        song.bpm = updated.referenceBPM
        try? SongProjectBridge.syncProjectFile(
            for: song,
            context: modelContext,
            timeline: state.timeline,
            tempoChanges: updated,
            timeSignatureChanges: state.timeSignatureChanges,
            midiEvents: state.midiEvents
        )
        try? modelContext.save()
    }

    private func song(for songID: UUID) -> Song? {
        guard let modelContext else { return nil }
        var descriptor = FetchDescriptor<Song>(predicate: #Predicate { $0.id == songID })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }
}
