import AVFoundation
import Foundation
#if canImport(Speech)
import Speech
#endif

/// Transcribes an audio file with Apple's on-device speech recognition, keeping when each
/// stretch of text was heard.
enum OnDeviceTranscriber {
    /// A run of transcribed text and the audio it covers.
    struct TimedText: Equatable, Sendable {
        var start: TimeInterval
        var end: TimeInterval
        var text: String
    }

    static var isAvailable: Bool {
        #if canImport(Speech)
        if #available(macOS 26, iOS 26, *) { return true }
        #endif
        return false
    }

    /// Runs of text in the order heard. Empty when the speech model for the current language
    /// isn't available or the transcription fails.
    static func transcribe(_ url: URL) async -> [TimedText] {
        #if canImport(Speech)
        guard #available(macOS 26, iOS 26, *) else { return [] }
        return await speechRuns(in: url)
        #else
        return []
        #endif
    }

    #if canImport(Speech)
    @available(macOS 26, iOS 26, *)
    private static func speechRuns(in url: URL) async -> [TimedText] {
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) ?? Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let file = try AVAudioFile(forReading: url)
            let collector = Task { () -> [TimedText] in
                var runs: [TimedText] = []
                for try await result in transcriber.results {
                    for run in result.text.runs {
                        guard let range = run.audioTimeRange else { continue }
                        runs.append(TimedText(
                            start: range.start.seconds,
                            end: range.end.seconds,
                            text: String(result.text[run.range].characters)
                        ))
                    }
                }
                return runs
            }
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            return try await collector.value
        } catch {
            return []
        }
    }
    #endif
}
