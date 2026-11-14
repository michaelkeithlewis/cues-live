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
            return "Section detection needs macOS 27 or iPadOS 27."
        case .noAudio:
            return "Add audio tracks before detecting sections."
        case .noSectionsFound:
            return "No sections were found in this song."
        }
    }
}

/// Finds section boundaries with Apple's Music Understanding framework.
///
/// The framework returns time ranges without labels, so detected sections are
/// named "Section N" and left for the user to rename.
enum SongSectionDetector {
    /// False when this binary was compiled without MusicUnderstanding.
    /// Xcode 26 and earlier omit the framework, so the menu stays hidden on macOS 27 until a rebuild with Xcode 27.
    static var isAvailable: Bool {
        #if canImport(MusicUnderstanding)
        if #available(macOS 27, iOS 27, *) { return true }
        #endif
        return false
    }

    /// Tracks that describe the song rather than belong to it; analyzing them would skew the result.
    static func analysisTracks(in song: Song) -> [AudioTrack] {
        song.sortedTracks.filter { track in
            let isClick = track.displayName.caseInsensitiveCompare(ClickTrackFileGenerator.trackDisplayName) == .orderedSame
            let isGuide = track.displayName.caseInsensitiveCompare(TrackGroupStore.guideGroupName) == .orderedSame
            return !isClick && !isGuide
        }
    }

    /// Section start times in seconds from the start of the song's audio files.
    static func detectSectionStarts(from urls: [URL]) async throws -> [TimeInterval] {
        #if canImport(MusicUnderstanding)
        guard #available(macOS 27, iOS 27, *) else { throw SongSectionDetectorError.unavailable }
        guard !urls.isEmpty else { throw SongSectionDetectorError.noAudio }

        let mix = try await SongAnalysisAudio.mixedAsset(from: urls)
        defer { if let cleanupURL = mix.cleanupURL { try? FileManager.default.removeItem(at: cleanupURL) } }

        let session = try await MusicUnderstandingSession(asset: mix.asset)
        let result = try await session.analyze(for: [.structure])
        let ranges = result.structure?.sections ?? []
        return ranges.map { $0.start.seconds }.filter { $0.isFinite }
        #else
        throw SongSectionDetectorError.unavailable
        #endif
    }

    /// Turns detected starts into markers: sorted, de-duplicated, with the first section pinned to 0
    /// so the opening of the song always belongs to a section.
    static func markers(
        fromSectionStarts starts: [TimeInterval],
        songDuration: TimeInterval,
        minimumSectionDuration: TimeInterval = 1
    ) -> [ArrangementMarker] {
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
        return kept.enumerated().map { index, start in
            ArrangementMarker(name: "Section \(index + 1)", startSeconds: start, sortOrder: index)
        }
    }
}
