import Foundation
import Observation
import SwiftData

/// Works out the tempo, key and sections of newly imported songs one at a time in the background, so
/// imports finish straight away and the songs can be edited while they are analyzed.
///
/// A detected tempo only replaces the opening tempo the song was imported with, and detected
/// sections and a detected key only fill a song that still has none. Anything changed by hand in
/// the meantime is kept. An editor showing the song applies the results itself so its own copy stays current.
@MainActor
@Observable
final class SongImportAnalyzer {
    static let shared = SongImportAnalyzer()

    /// What an import still needs from the analysis.
    struct Needs: OptionSet, Sendable {
        let rawValue: Int
        static let tempo = Needs(rawValue: 1 << 0)
        static let sections = Needs(rawValue: 1 << 1)
        static let key = Needs(rawValue: 1 << 2)
    }

    /// Results waiting for the editor showing the song to apply them.
    struct EditorResult: Equatable {
        var bpm: Double?
        var importedBPM: Double
        var sections: [ArrangementMarker]?
    }

    private struct Job {
        let songID: UUID
        let importedBPM: Double
        let needs: Needs
    }

    /// Songs waiting for or undergoing analysis, for showing progress in the library.
    private(set) var pendingSongIDs: Set<UUID> = []
    private(set) var editorResults: [UUID: EditorResult] = [:]

    private var queue: [Job] = []
    private var editingSongIDs: Set<UUID> = []
    private var worker: Task<Void, Never>?
    private var modelContext: ModelContext?

    private init() {}

    func enqueue(_ song: Song, needs: Needs, context: ModelContext) {
        var needs = needs
        if !SongTempoDetector.isAvailable { needs.remove(.tempo) }
        if !SongSectionDetector.canDetect(in: song) { needs.remove(.sections) }
        if !SongKeyDetector.isSupported { needs.remove(.key) }
        guard !needs.isEmpty, !pendingSongIDs.contains(song.id) else { return }
        modelContext = context
        queue.append(Job(songID: song.id, importedBPM: song.bpm ?? TempoChange.defaultBPM, needs: needs))
        pendingSongIDs.insert(song.id)
        startWorkerIfNeeded()
    }

    func beginEditing(_ songID: UUID) {
        editingSongIDs.insert(songID)
    }

    /// Writes results the editor never got to apply straight to the song.
    func endEditing(_ songID: UUID) {
        editingSongIDs.remove(songID)
        if let result = editorResults.removeValue(forKey: songID) {
            applyToStoredSong(songID, result: result)
        }
    }

    /// Hands the editor its results, once.
    func takeEditorResult(for songID: UUID) -> EditorResult? {
        editorResults.removeValue(forKey: songID)
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
        var result = EditorResult(bpm: nil, importedBPM: job.importedBPM, sections: nil)

        if job.needs.contains(.tempo) {
            let urls = SongTempoDetector.analysisURLs(
                fromStems: song.sortedTracks.compactMap { FileStore.trackURL(for: song, track: $0) }
            )
            if let bpm = try? await SongTempoDetector.detectBPM(from: urls), bpm != job.importedBPM {
                result.bpm = bpm
            }
        }

        if job.needs.contains(.sections), let song = self.song(for: job.songID) {
            let state = SongProjectBridge.projectStateOrDefaults(for: song)
            let duration = state.timeline.duration
            let measureStarts = SongGuideCueReader.measureStarts(
                tempoChanges: Self.tempoChanges(state.tempoChanges, settingOpeningBPM: result.bpm, fallback: job.importedBPM),
                timeSignatureChanges: state.timeSignatureChanges.normalizedEnsuringInitialMarker(
                    defaultNumerator: song.timeSignatureNumerator ?? TimeSignatureChange.defaultNumerator,
                    defaultDenominator: song.timeSignatureDenominator ?? TimeSignatureChange.defaultDenominator
                ),
                through: duration
            )
            let sections = try? await SongSectionDetector.detectSections(
                SongSectionDetector.sources(for: song),
                measureStarts: measureStarts,
                songDuration: duration
            )
            if let sections, sections.count > 1 {
                result.sections = sections
            }
        }

        if job.needs.contains(.key), let song = self.song(for: job.songID) {
            let urls = SongSectionDetector.analysisTracks(in: song).compactMap { FileStore.trackURL(for: song, track: $0) }
            if let detected = try? await SongKeyDetector.detectKey(trackURLs: urls) {
                applyKey(detected, to: job.songID)
            }
        }

        guard result.bpm != nil || result.sections != nil else { return }
        if editingSongIDs.contains(job.songID) {
            editorResults[job.songID] = result
        } else {
            applyToStoredSong(job.songID, result: result)
        }
    }

    private func applyToStoredSong(_ songID: UUID, result: EditorResult) {
        guard let modelContext, let song = song(for: songID) else { return }
        let state = SongProjectBridge.projectStateOrDefaults(for: song)
        var tempo = state.tempoChanges.normalizedEnsuringInitialMarker(defaultBPM: song.bpm ?? result.importedBPM)
        if let bpm = result.bpm, tempo.first(where: \.isOrigin)?.bpm == result.importedBPM {
            tempo = Self.tempoChanges(tempo, settingOpeningBPM: bpm, fallback: result.importedBPM)
            song.bpm = tempo.referenceBPM
        }
        var timeline = state.timeline
        if let sections = result.sections, timeline.markers.count <= 1 {
            timeline.markers = sections
        }
        try? SongProjectBridge.syncProjectFile(
            for: song,
            context: modelContext,
            timeline: timeline,
            tempoChanges: tempo,
            timeSignatureChanges: state.timeSignatureChanges,
            midiEvents: state.midiEvents
        )
        try? modelContext.save()
    }

    /// The key lives on the song rather than in the editor's state, so it is applied straight away.
    private func applyKey(_ detected: SongKeyDetector.DetectedKey, to songID: UUID) {
        guard let modelContext, let song = song(for: songID), song.baseKeyRaw == nil else { return }
        song.baseKeyRaw = detected.key.rawValue
        song.keyModeRaw = detected.mode.storedRaw
        let state = SongProjectBridge.projectStateOrDefaults(for: song)
        try? SongProjectBridge.syncProjectFile(
            for: song,
            context: modelContext,
            timeline: state.timeline,
            tempoChanges: state.tempoChanges,
            timeSignatureChanges: state.timeSignatureChanges,
            midiEvents: state.midiEvents
        )
        try? modelContext.save()
    }

    /// The tempo map with its opening tempo set to `bpm`, or left as it is when `bpm` is nil.
    static func tempoChanges(
        _ changes: [TempoChange],
        settingOpeningBPM bpm: Double?,
        fallback: Double
    ) -> [TempoChange] {
        var updated = changes.normalizedEnsuringInitialMarker(defaultBPM: fallback)
        guard let bpm, let index = updated.firstIndex(where: \.isOrigin) else { return updated }
        let origin = updated[index]
        updated[index] = TempoChange(
            id: origin.id,
            startMeasure: origin.startMeasure,
            beatOffset: origin.beatOffset,
            bpm: bpm,
            sortOrder: origin.sortOrder
        )
        return updated
    }

    private func song(for songID: UUID) -> Song? {
        guard let modelContext else { return nil }
        var descriptor = FetchDescriptor<Song>(predicate: #Predicate { $0.id == songID })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }
}
