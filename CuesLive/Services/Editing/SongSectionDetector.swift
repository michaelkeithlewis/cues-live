import AVFoundation
import Foundation
#if canImport(MusicUnderstanding)
import MusicUnderstanding
#endif

enum SongSectionDetectorError: LocalizedError {
    case unavailable
    case noAudio
    case noSectionsFound

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Section detection needs a spoken guide track, or macOS 27 or iPadOS 27."
        case .noAudio:
            return "Add audio tracks before detecting sections."
        case .noSectionsFound:
            return "No sections were found in this song."
        }
    }
}

/// Finds and names a song's sections.
///
/// A spoken guide track is read first, since it says what each section is. Without one, Apple's
/// Music Understanding framework finds the boundaries and `SongSectionLabeler` names them from the
/// song's shape (intro, verse, chorus, bridge), falling back to "Section N".
enum SongSectionDetector {
    /// The audio a detection reads, gathered from the song up front.
    struct Sources: Sendable {
        var analysisURLs: [URL]
        var lyricURLs: [URL]
        var guideURLs: [URL]
    }

    /// True when Music Understanding is in this build and running OS, so sections can be found
    /// without a guide. Xcode 26 and earlier omit the framework.
    static var canAnalyzeStructure: Bool {
        #if canImport(MusicUnderstanding)
        if #available(macOS 27, iOS 27, *) { return true }
        #endif
        return false
    }

    static var isAvailable: Bool {
        canAnalyzeStructure || OnDeviceTranscriber.isAvailable
    }

    /// Track groups that describe the song rather than belong to it, like a click or timecode.
    private static let nonMusicGroupNames: Set<String> = ["click", "timecode", TrackGroupStore.guideGroupName.lowercased()]
    private static let leadVocalGroupName = "lv"

    /// Tracks that describe the song rather than belong to it; analyzing them would skew the result.
    static func analysisTracks(in song: Song) -> [AudioTrack] {
        let guideIDs = Set(SongGuideCueReader.guideTracks(in: song).map(\.id))
        return song.sortedTracks.filter { track in
            let isClick = track.displayName.caseInsensitiveCompare(TrackGroupStore.clickGroupName) == .orderedSame
            let isNonMusicGroup = track.group.map { nonMusicGroupNames.contains($0.name.lowercased()) } ?? false
            return !isClick && !isNonMusicGroup && !guideIDs.contains(track.id)
        }
    }

    /// Lead vocal tracks, which transcribe far better on their own than inside the full mix.
    static func lyricTracks(in tracks: [AudioTrack]) -> [AudioTrack] {
        tracks.filter { $0.group?.name.lowercased() == leadVocalGroupName }
    }

    /// Whether the song has anything detection can read on this device.
    static func canDetect(in song: Song) -> Bool {
        (OnDeviceTranscriber.isAvailable && !SongGuideCueReader.guideTracks(in: song).isEmpty)
            || (canAnalyzeStructure && !analysisTracks(in: song).isEmpty)
    }

    static func sources(for song: Song) -> Sources {
        let tracks = analysisTracks(in: song)
        let urls = { (tracks: [AudioTrack]) in tracks.compactMap { FileStore.trackURL(for: song, track: $0) } }
        return Sources(
            analysisURLs: urls(tracks),
            lyricURLs: urls(lyricTracks(in: tracks)),
            guideURLs: urls(SongGuideCueReader.guideTracks(in: song))
        )
    }

    /// Named sections as markers.
    ///
    /// - Parameter measureStarts: Bar line times, where guide calls place their sections.
    static func detectSections(
        _ sources: Sources,
        measureStarts: [TimeInterval],
        songDuration: TimeInterval
    ) async throws -> [ArrangementMarker] {
        if !sources.guideURLs.isEmpty {
            let cues = await SongGuideCueReader.spokenCues(in: sources.guideURLs)
            let guided = SongGuideCueReader.markers(from: cues, measureStarts: measureStarts, songDuration: songDuration)
            if guided.count > 1 { return guided }
        }
        return try await analyzeStructure(
            from: sources.analysisURLs,
            lyricURLs: sources.lyricURLs,
            songDuration: songDuration
        )
    }

    /// Turns detected starts into markers named "Section N".
    static func markers(
        fromSectionStarts starts: [TimeInterval],
        songDuration: TimeInterval,
        minimumSectionDuration: TimeInterval = 1
    ) -> [ArrangementMarker] {
        sectionStarts(from: starts, songDuration: songDuration, minimumSectionDuration: minimumSectionDuration)
            .enumerated()
            .map { index, start in
                ArrangementMarker(name: "Section \(index + 1)", startSeconds: start, sortOrder: index)
            }
    }

    /// Sorted, de-duplicated starts with the first pinned to 0 so the opening of the song always
    /// belongs to a section.
    static func sectionStarts(
        from starts: [TimeInterval],
        songDuration: TimeInterval,
        minimumSectionDuration: TimeInterval = 1
    ) -> [TimeInterval] {
        let limit = songDuration > 0 ? songDuration : .greatestFiniteMagnitude
        var kept: [TimeInterval] = [0]
        for start in starts.sorted() where start > 0 && start < limit {
            if start - kept[kept.count - 1] < minimumSectionDuration { continue }
            kept.append(start)
        }
        // A short tail would become a section of its own; fold it into the previous one.
        if kept.count > 1, songDuration > 0, songDuration - kept[kept.count - 1] < minimumSectionDuration {
            kept.removeLast()
        }
        return kept
    }

    // MARK: - Private

    /// Boundaries from Music Understanding, named from the song's shape.
    ///
    /// - Parameter lyricURLs: Lead vocal files to transcribe; the full mix is transcribed when empty.
    private static func analyzeStructure(
        from urls: [URL],
        lyricURLs: [URL],
        songDuration: TimeInterval
    ) async throws -> [ArrangementMarker] {
        #if canImport(MusicUnderstanding)
        guard #available(macOS 27, iOS 27, *) else { throw SongSectionDetectorError.unavailable }
        guard !urls.isEmpty else { throw SongSectionDetectorError.noAudio }

        let mix = try await SongAnalysisAudio.mixedAsset(from: urls)
        defer { if let cleanupURL = mix.cleanupURL { try? FileManager.default.removeItem(at: cleanupURL) } }

        let session = try await MusicUnderstandingSession(asset: mix.asset)
        let result = try await session.analyze(for: [.structure, .instrumentActivity, .rhythm])
        let detected = (result.structure?.sections ?? []).map { $0.start.seconds }.filter { $0.isFinite }
        let starts = sectionStarts(from: detected, songDuration: songDuration)

        guard starts.count > 1,
              let labels = await labels(
                  forSectionStarts: starts,
                  result: result,
                  mix: mix,
                  lyricURLs: lyricURLs,
                  songDuration: songDuration
              ) else {
            return markers(fromSectionStarts: starts, songDuration: songDuration)
        }
        return labels.enumerated().map { index, label in
            ArrangementMarker(name: label.name, startSeconds: label.start, sortOrder: index)
        }
        #else
        throw SongSectionDetectorError.unavailable
        #endif
    }

    #if canImport(MusicUnderstanding)
    @available(macOS 27, iOS 27, *)
    private static func labels(
        forSectionStarts starts: [TimeInterval],
        result: MusicUnderstandingSession.SessionResult,
        mix: SongAnalysisAudio.MixedAsset,
        lyricURLs: [URL],
        songDuration: TimeInterval
    ) async -> [SongSectionLabeler.Label]? {
        guard let audio = try? await SongSectionProfiler.measure(mix.asset) else { return nil }
        let songEnd = songDuration > 0 ? songDuration : audio.duration
        let vocalRanges = (result.instrumentActivity?.ranges[.vocal] ?? []).map { range in
            (start: range.start.seconds, end: range.end.seconds)
        }
        let beats = (result.rhythm?.beats ?? []).map(\.seconds)
        let words = await transcribedWords(lyricURLs: lyricURLs, mix: mix)

        let profiles = SongSectionProfiler.profiles(
            sectionStarts: starts,
            songEnd: songEnd,
            vocalRanges: vocalRanges,
            words: words,
            audio: audio
        )
        let similarity = SongSectionProfiler.audioSimilarity(
            sectionStarts: starts,
            songEnd: songEnd,
            beats: beats,
            audio: audio
        )
        return SongSectionLabeler.label(profiles, audioSimilarity: similarity)
    }
    #endif

    private static func transcribedWords(
        lyricURLs: [URL],
        mix: SongAnalysisAudio.MixedAsset
    ) async -> [SongSectionProfiler.TimedWord] {
        guard !lyricURLs.isEmpty else { return await SongSectionProfiler.transcribedWords(in: mix.asset.url) }
        guard let vocals = try? await SongAnalysisAudio.mixedAsset(from: lyricURLs) else { return [] }
        defer { if let cleanupURL = vocals.cleanupURL { try? FileManager.default.removeItem(at: cleanupURL) } }
        return await SongSectionProfiler.transcribedWords(in: vocals.asset.url)
    }
}
