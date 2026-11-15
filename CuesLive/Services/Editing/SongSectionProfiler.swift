import Accelerate
import AVFoundation
import Foundation

/// Measures each detected section so `SongSectionLabeler` can name it: how much of it is sung,
/// how loud it is, what words are in it, and how much it sounds like every other section.
enum SongSectionProfiler {
    /// Pitch-class and level frames read from the song mix.
    struct AudioMeasurements {
        var frameDuration: TimeInterval
        var firstFrameCenter: TimeInterval
        /// One 12-bin pitch-class vector per frame, scaled to unit length.
        var chroma: [[Float]]
        /// RMS level per frame in dB.
        var levels: [Float]
        var duration: TimeInterval
    }

    struct TimedWord: Equatable {
        var time: TimeInterval
        var word: String
    }

    static let sampleRate = 22_050.0
    private static let frameSize = 8_192
    private static let hopSize = 2_048
    private static let lowestPitch = 60.0
    private static let highestPitch = 5_000.0
    /// Without a usable beat grid, sections are compared in slices this long.
    private static let fallbackBeatDuration: TimeInterval = 0.5

    /// - Parameters:
    ///   - starts: Section starts in ascending order, the first at 0.
    ///   - vocalRanges: Where the analysis hears a voice, in seconds.
    static func profiles(
        sectionStarts starts: [TimeInterval],
        songEnd: TimeInterval,
        vocalRanges: [(start: TimeInterval, end: TimeInterval)],
        words: [TimedWord],
        audio: AudioMeasurements
    ) -> [SectionProfile] {
        starts.indices.map { index in
            let start = starts[index]
            let end = index + 1 < starts.count ? starts[index + 1] : songEnd
            let length = max(end - start, .ulpOfOne)
            let sungTime = vocalRanges.reduce(0.0) { total, range in
                total + max(0, min(end, range.end) - max(start, range.start))
            }
            let levels = frameIndices(from: start, to: end, audio: audio).map { audio.levels[$0] }
            return SectionProfile(
                start: start,
                end: end,
                vocalCoverage: min(1, sungTime / length),
                loudness: powerMean(levels),
                words: words.filter { $0.time >= start && $0.time < end }.map(\.word)
            )
        }
    }

    /// How alike each pair of sections sounds, 0...1. Each section slides beat by beat along the other,
    /// spilling up to half its length past either edge, so two choruses still match when the detected
    /// boundaries landed in different places.
    static func audioSimilarity(
        sectionStarts starts: [TimeInterval],
        songEnd: TimeInterval,
        beats: [TimeInterval],
        audio: AudioMeasurements
    ) -> [[Float]] {
        let grid = beatGrid(beats, songEnd: songEnd)
        let chroma = centeredBeatChroma(grid: grid, songEnd: songEnd, audio: audio)
        let ranges: [Range<Int>] = starts.indices.map { index in
            let end = index + 1 < starts.count ? starts[index + 1] : songEnd
            let lower = grid.firstIndex { $0 >= starts[index] } ?? grid.count
            let upper = grid.firstIndex { $0 >= end } ?? grid.count
            return lower..<max(lower, upper)
        }

        func directed(_ source: Range<Int>, _ target: Range<Int>) -> Float {
            let length = source.count
            guard length >= 2, target.count >= 2 else { return 0 }
            let minimumOverlap = min(length, target.count) / 2
            var best: Float = 0
            let first = max(0, target.lowerBound - length / 2)
            let last = min(chroma.count - length, target.upperBound - length / 2)
            guard first <= last else { return 0 }
            for offset in first...last where abs(offset - source.lowerBound) >= length / 2 {
                let overlap = min(offset + length, target.upperBound) - max(offset, target.lowerBound)
                guard overlap >= minimumOverlap else { continue }
                var total: Float = 0
                for step in 0..<length {
                    total += vDSP.dot(chroma[source.lowerBound + step], chroma[offset + step])
                }
                best = max(best, total / Float(length))
            }
            return best
        }

        return ranges.indices.map { i in
            ranges.indices.map { j in
                i == j ? 1 : max(0, max(directed(ranges[i], ranges[j]), directed(ranges[j], ranges[i])))
            }
        }
    }

    /// Reads the asset's first audio track as mono at `sampleRate` and measures it frame by frame.
    static func measure(_ asset: AVAsset) async throws -> AudioMeasurements {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw SongSectionDetectorError.noAudio
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ])
        reader.add(output)
        guard reader.startReading() else { throw SongAnalysisAudio.AnalysisAudioError.mixFailed }

        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = chunk.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
            }
            if status == kCMBlockBufferNoErr { samples.append(contentsOf: chunk) }
        }
        guard reader.status == .completed else { throw SongAnalysisAudio.AnalysisAudioError.mixFailed }
        return measure(samples: samples)
    }

    static func measure(samples: [Float]) -> AudioMeasurements {
        var measurements = AudioMeasurements(
            frameDuration: Double(hopSize) / sampleRate,
            firstFrameCenter: Double(frameSize / 2) / sampleRate,
            chroma: [],
            levels: [],
            duration: Double(samples.count) / sampleRate
        )
        let log2n = vDSP_Length(log2(Double(frameSize)))
        guard samples.count >= frameSize,
              let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return measurements }
        defer { vDSP_destroy_fftsetup(setup) }

        let half = frameSize / 2
        let pitchClassOfBin: [Int] = (0..<half).map { bin in
            let frequency = Double(bin) * sampleRate / Double(frameSize)
            guard frequency >= lowestPitch, frequency <= highestPitch else { return -1 }
            let midi = Int((69 + 12 * log2(frequency / 440)).rounded())
            return ((midi % 12) + 12) % 12
        }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: frameSize, isHalfWindow: false)
        var frame = [Float](repeating: 0, count: frameSize)
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)

        var offset = 0
        while offset + frameSize <= samples.count {
            let slice = samples[offset..<(offset + frameSize)]
            measurements.levels.append(20 * log10(vDSP.rootMeanSquare(slice) + 1e-9))
            vDSP.multiply(slice, window, result: &frame)

            real.withUnsafeMutableBufferPointer { realPointer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                    var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                    frame.withUnsafeBytes { bytes in
                        vDSP_ctoz(bytes.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                    magnitudes.withUnsafeMutableBufferPointer { magnitudePointer in
                        vDSP_zvabs(&split, 1, magnitudePointer.baseAddress!, 1, vDSP_Length(half))
                    }
                }
            }

            var pitchClasses = [Float](repeating: 0, count: 12)
            for bin in 1..<half where pitchClassOfBin[bin] >= 0 {
                pitchClasses[pitchClassOfBin[bin]] += magnitudes[bin]
            }
            measurements.chroma.append(unitLength(pitchClasses))
            offset += hopSize
        }
        return measurements
    }

    /// Words in the audio with the time each was heard, lowercased.
    static func transcribedWords(in url: URL) async -> [TimedWord] {
        await OnDeviceTranscriber.transcribe(url).flatMap { run -> [TimedWord] in
            let tokens = run.text
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
                .filter { !$0.isEmpty }
            // A run can hold several words; spread them evenly across its time range.
            let step = tokens.isEmpty ? 0 : (run.end - run.start) / Double(tokens.count)
            return tokens.enumerated().map { position, token in
                TimedWord(time: run.start + step * Double(position), word: token)
            }
        }
    }

    // MARK: - Private

    private static func beatGrid(_ beats: [TimeInterval], songEnd: TimeInterval) -> [TimeInterval] {
        var grid = beats.filter { $0 >= 0 && $0 < songEnd }.sorted()
        if grid.count < 16 {
            grid = Array(stride(from: 0, to: songEnd, by: fallbackBeatDuration))
        } else if let first = grid.first, first > fallbackBeatDuration / 2 {
            grid.insert(0, at: 0)
        }
        return grid
    }

    /// Averages frames per beat, subtracts the song's average beat so the shared key color drops out,
    /// and rescales each beat to unit length so a dot product is a cosine.
    private static func centeredBeatChroma(grid: [TimeInterval], songEnd: TimeInterval, audio: AudioMeasurements) -> [[Float]] {
        let zero = [Float](repeating: 0, count: 12)
        var beats: [[Float]] = grid.indices.map { index in
            let end = index + 1 < grid.count ? grid[index + 1] : songEnd
            let frames = frameIndices(from: grid[index], to: end, audio: audio)
            guard !frames.isEmpty else { return zero }
            var total = zero
            for frame in frames { total = vDSP.add(total, audio.chroma[frame]) }
            return unitLength(total)
        }
        guard !beats.isEmpty else { return [] }
        var average = zero
        for beat in beats { average = vDSP.add(average, beat) }
        average = vDSP.divide(average, Float(beats.count))
        beats = beats.map { unitLength(vDSP.subtract($0, average)) }
        return beats
    }

    private static func unitLength(_ vector: [Float]) -> [Float] {
        let norm = vDSP.sumOfSquares(vector).squareRoot()
        return norm > 0 ? vDSP.divide(vector, norm) : vector
    }

    private static func frameIndices(from start: TimeInterval, to end: TimeInterval, audio: AudioMeasurements) -> Range<Int> {
        let count = audio.levels.count
        guard count > 0, audio.frameDuration > 0 else { return 0..<0 }
        let first = Int(((start - audio.firstFrameCenter) / audio.frameDuration).rounded(.up))
        let last = Int(((end - audio.firstFrameCenter) / audio.frameDuration).rounded(.up))
        let lower = min(max(first, 0), count)
        let upper = min(max(last, lower), count)
        return lower..<upper
    }

    private static func powerMean(_ levels: [Float]) -> Double {
        guard !levels.isEmpty else { return -100 }
        let power = levels.reduce(0.0) { $0 + pow(10, Double($1) / 10) } / Double(levels.count)
        return 10 * log10(max(power, 1e-10))
    }
}
