import AVFoundation
import Foundation
#if canImport(MusicUnderstanding)
import MusicUnderstanding
#endif

enum SongSectionDetectorError: LocalizedError {
    case unavailable
    case noAudio
    case mixFailed
    case noSectionsFound

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Section detection needs macOS 27 or iPadOS 27."
        case .noAudio:
            return "Add audio tracks before detecting sections."
        case .mixFailed:
            return "Couldn't prepare the song audio for analysis."
        case .noSectionsFound:
            return "No sections were found in this song."
        }
    }
}

/// Finds section boundaries with Apple's Music Understanding framework.
///
/// The framework returns time ranges without labels. `SongSectionLabeler` names them from the
/// song's shape (intro, verse, chorus, bridge); when that fails they fall back to "Section N".
enum SongSectionDetector {
    static var isAvailable: Bool {
        #if canImport(MusicUnderstanding)
        if #available(macOS 27, iOS 27, *) { return true }
        #endif
        return false
    }

    /// Track groups that describe the song rather than belong to it, like a click or timecode.
    private static let nonMusicGroupNames: Set<String> = ["click", "timecode", TrackGroupStore.guideGroupName.lowercased()]
    private static let leadVocalGroupName = "lv"

    /// Tracks that describe the song rather than belong to it; analyzing them would skew the result.
    static func analysisTracks(in song: Song) -> [AudioTrack] {
        song.sortedTracks.filter { track in
            let isClick = track.displayName.caseInsensitiveCompare(ClickTrackFileGenerator.trackDisplayName) == .orderedSame
            let isGuide = track.displayName.caseInsensitiveCompare(TrackGroupStore.guideGroupName) == .orderedSame
            let isNonMusicGroup = track.group.map { nonMusicGroupNames.contains($0.name.lowercased()) } ?? false
            return !isClick && !isGuide && !isNonMusicGroup
        }
    }

    /// Lead vocal tracks, which transcribe far better on their own than inside the full mix.
    static func lyricTracks(in tracks: [AudioTrack]) -> [AudioTrack] {
        tracks.filter { $0.group?.name.lowercased() == leadVocalGroupName }
    }

    /// Detected sections as markers, named from the song's shape, or "Section N" when naming fails.
    ///
    /// - Parameter lyricURLs: Lead vocal files to transcribe; the full mix is transcribed when empty.
    static func detectSections(
        from urls: [URL],
        lyricURLs: [URL],
        songDuration: TimeInterval
    ) async throws -> [ArrangementMarker] {
        #if canImport(MusicUnderstanding)
        guard #available(macOS 27, iOS 27, *) else { throw SongSectionDetectorError.unavailable }
        guard !urls.isEmpty else { throw SongSectionDetectorError.noAudio }

        let mix = try await mixedAsset(from: urls)
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

    #if canImport(MusicUnderstanding)
    @available(macOS 27, iOS 27, *)
    private static func labels(
        forSectionStarts starts: [TimeInterval],
        result: MusicUnderstandingSession.SessionResult,
        mix: MixedAsset,
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

    @available(macOS 27, iOS 27, *)
    private static func transcribedWords(lyricURLs: [URL], mix: MixedAsset) async -> [SongSectionProfiler.TimedWord] {
        #if canImport(Speech)
        guard !lyricURLs.isEmpty else { return await SongSectionProfiler.transcribedWords(in: mix.asset.url) }
        guard let vocals = try? await mixedAsset(from: lyricURLs) else { return [] }
        defer { if let cleanupURL = vocals.cleanupURL { try? FileManager.default.removeItem(at: cleanupURL) } }
        return await SongSectionProfiler.transcribedWords(in: vocals.asset.url)
        #else
        return []
        #endif
    }
    #endif

    private struct MixedAsset {
        let asset: AVURLAsset
        let cleanupURL: URL?
    }

    /// One track is analyzed in place; several are summed into a temporary file so the analysis hears the full mix.
    private static func mixedAsset(from urls: [URL]) async throws -> MixedAsset {
        let options = [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        if urls.count == 1 {
            return MixedAsset(asset: AVURLAsset(url: urls[0], options: options), cleanupURL: nil)
        }

        let composition = AVMutableComposition()
        for url in urls {
            let source = AVURLAsset(url: url)
            guard let sourceTrack = try await source.loadTracks(withMediaType: .audio).first,
                  let compositionTrack = composition.addMutableTrack(
                      withMediaType: .audio,
                      preferredTrackID: kCMPersistentTrackID_Invalid
                  ) else { continue }
            let duration = try await source.load(.duration)
            try compositionTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: sourceTrack,
                at: .zero
            )
        }
        guard !composition.tracks(withMediaType: .audio).isEmpty,
              let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw SongSectionDetectorError.mixFailed
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cues-section-analysis-\(UUID().uuidString).m4a")
        do {
            try await export.export(to: outputURL, as: .m4a)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw SongSectionDetectorError.mixFailed
        }
        return MixedAsset(asset: AVURLAsset(url: outputURL, options: options), cleanupURL: outputURL)
    }
}
