import Foundation

/// Settles a song folder's name, tempo and meter without asking: an Ableton set wins, then a tempo
/// detected from the stems, then the defaults. "Song Setup…" on the song changes them afterwards.
enum SongFolderAutoSetup {
    @MainActor
    static func request(for preview: SongFolderImporter.Preview) async -> SongFolderImporter.ImportRequest {
        let bpm: Double
        if let abletonBPM = preview.bpm {
            bpm = abletonBPM
        } else {
            bpm = await detectedBPM(for: preview) ?? TempoChange.defaultBPM
        }
        return SongFolderImporter.ImportRequest(
            folderURL: preview.folderURL,
            settings: SongFolderImporter.ImportSettings(
                name: preview.suggestedName,
                bpm: bpm,
                timeSignatureNumerator: preview.timeSignatureNumerator ?? TimeSignatureChange.defaultNumerator,
                timeSignatureDenominator: preview.timeSignatureDenominator ?? TimeSignatureChange.defaultDenominator,
                baseKeyRaw: nil
            )
        )
    }

    private static func detectedBPM(for preview: SongFolderImporter.Preview) async -> Double? {
        let urls = SongTempoDetector.analysisURLs(fromStems: preview.trackURLs)
        guard SongTempoDetector.isAvailable, !urls.isEmpty else { return nil }
        let didAccess = preview.folderURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                preview.folderURL.stopAccessingSecurityScopedResource()
            }
        }
        return try? await SongTempoDetector.detectBPM(from: urls)
    }
}
