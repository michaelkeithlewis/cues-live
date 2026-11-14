import CoreMedia
import Foundation
#if canImport(MusicUnderstanding)
import MusicUnderstanding
#endif

enum SongTempoDetectorError: LocalizedError {
    case unavailable
    case noAudio
    case noTempoFound

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Tempo detection needs macOS 27 or iPadOS 27."
        case .noAudio:
            return "Add audio tracks before detecting tempo."
        case .noTempoFound:
            return "No steady tempo was found in this song."
        }
    }
}

/// Finds a song's tempo with Apple's Music Understanding framework.
enum SongTempoDetector {
    static var isAvailable: Bool { SongSectionDetector.isAvailable }

    /// Audio worth analyzing from an imported folder. A click stem states the tempo outright, so it is
    /// analyzed alone; otherwise every stem but spoken guides goes into the mix.
    static func analysisURLs(fromStems urls: [URL]) -> [URL] {
        let named = urls.map { ($0, $0.deletingPathExtension().lastPathComponent.lowercased()) }
        if let click = named.first(where: { $0.1.contains("click") }) {
            return [click.0]
        }
        return named.filter { !$0.1.contains("guide") }.map(\.0)
    }

    static func detectBPM(from urls: [URL]) async throws -> Double {
        #if canImport(MusicUnderstanding)
        guard #available(macOS 27, iOS 27, *) else { throw SongTempoDetectorError.unavailable }
        guard !urls.isEmpty else { throw SongTempoDetectorError.noAudio }

        let mix = try await SongAnalysisAudio.mixedAsset(from: urls)
        defer { if let cleanupURL = mix.cleanupURL { try? FileManager.default.removeItem(at: cleanupURL) } }

        let session = try await MusicUnderstandingSession(asset: mix.asset)
        let rhythm = try await session.analyze(for: [.rhythm]).rhythm
        let detected = rhythm?.beatsPerMinute.map(Double.init)
            ?? bpm(fromBeatTimes: rhythm?.beats.map(\.seconds) ?? [])
        guard let bpm = detected.flatMap(normalizedBPM) else { throw SongTempoDetectorError.noTempoFound }
        return bpm
        #else
        throw SongTempoDetectorError.unavailable
        #endif
    }

    /// Tempo from the median gap between beats, so a few missed or extra beats don't skew it.
    static func bpm(fromBeatTimes times: [TimeInterval]) -> Double? {
        let sorted = times.filter(\.isFinite).sorted()
        let gaps = zip(sorted.dropFirst(), sorted).map { $0 - $1 }.filter { $0 > 0 }.sorted()
        guard gaps.count >= 4 else { return nil }
        return 60 / gaps[gaps.count / 2]
    }

    /// Snaps near-whole tempos to the whole number, since recorded songs almost always sit on one,
    /// and keeps the result inside the range the tempo map accepts.
    static func normalizedBPM(_ value: Double) -> Double? {
        guard value.isFinite, TempoChange.validBPMRange.contains(value) else { return nil }
        let whole = value.rounded()
        if abs(value - whole) <= 0.2 { return whole }
        return (value * 10).rounded() / 10
    }
}
