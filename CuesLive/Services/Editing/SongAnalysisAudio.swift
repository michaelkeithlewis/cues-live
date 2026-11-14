import AVFoundation
import Foundation

/// Prepares a song's audio files as one asset for Music Understanding analysis.
enum SongAnalysisAudio {
    enum AnalysisAudioError: LocalizedError {
        case mixFailed

        var errorDescription: String? {
            "Couldn't prepare the song audio for analysis."
        }
    }

    struct MixedAsset {
        let asset: AVURLAsset
        let cleanupURL: URL?
    }

    /// One file is analyzed in place; several are summed into a temporary file so the analysis hears the full mix.
    /// Remove `cleanupURL` when the analysis finishes.
    static func mixedAsset(from urls: [URL]) async throws -> MixedAsset {
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
            throw AnalysisAudioError.mixFailed
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cues-song-analysis-\(UUID().uuidString).m4a")
        do {
            try await export.export(to: outputURL, as: .m4a)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw AnalysisAudioError.mixFailed
        }
        return MixedAsset(asset: AVURLAsset(url: outputURL, options: options), cleanupURL: outputURL)
    }
}
