import Foundation

/// Reads section names from a spoken guide track ("Verse one", "Pre chorus", "Bridge") with
/// on-device speech recognition. A guide calls each section in the bar before it starts, so a
/// section begins at the first bar line after its call.
enum SongGuideCueReader {
    /// One transcribed phrase from the guide.
    struct SpokenCue: Equatable, Sendable {
        var start: TimeInterval
        var end: TimeInterval
        var text: String
    }

    /// Words that name a part of the song, longest first so "pre chorus" wins over "chorus".
    private static let sectionPhrases: [(words: [String], name: String)] = [
        (["pre", "chorus"], "Pre-Chorus"),
        (["prechorus"], "Pre-Chorus"),
        (["post", "chorus"], "Post-Chorus"),
        (["postchorus"], "Post-Chorus"),
        (["intro"], "Intro"),
        (["verse"], "Verse"),
        (["chorus"], "Chorus"),
        (["bridge"], "Bridge"),
        (["refrain"], "Refrain"),
        (["hook"], "Hook"),
        (["interlude"], "Interlude"),
        (["instrumental"], "Instrumental"),
        (["solo"], "Solo"),
        (["turnaround"], "Turnaround"),
        (["vamp"], "Vamp"),
        (["tag"], "Tag"),
        (["rap"], "Rap"),
        (["outro"], "Outro"),
        (["ending"], "Ending")
    ]

    /// Names numbered when they come back, matching how the labeler numbers them.
    private static let numberedNames: Set<String> = ["Verse", "Pre-Chorus", "Chorus", "Bridge"]

    /// A cue that ends this close before a bar line still starts the section at that bar line.
    private static let barLineTolerance: TimeInterval = 0.05

    /// Tracks that look like a spoken guide: the Cues group, or a name with "guide" or "cue" in it.
    static func guideTracks(in song: Song) -> [AudioTrack] {
        song.sortedTracks.filter { track in
            if track.group?.name.caseInsensitiveCompare(TrackGroupStore.guideGroupName) == .orderedSame {
                return true
            }
            let name = track.displayName.lowercased()
            return name.contains("guide") || name.contains("cue")
        }
    }

    /// The section a guide phrase calls, or nil for dynamics like "build", "all in" or a count-in.
    static func sectionName(for phrase: String) -> String? {
        let words = phrase.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        for index in words.indices {
            for entry in sectionPhrases {
                let end = index + entry.words.count
                guard end <= words.count, Array(words[index..<end]) == entry.words else { continue }
                return entry.name
            }
        }
        return nil
    }

    /// Sections from the guide's calls, each starting at the first bar line after its call.
    /// Repeated calls of the same part merge, and returning parts are numbered.
    ///
    /// - Parameter measureStarts: Bar line times in ascending order.
    static func markers(
        from cues: [SpokenCue],
        measureStarts: [TimeInterval],
        songDuration: TimeInterval
    ) -> [ArrangementMarker] {
        var named: [(start: TimeInterval, name: String)] = []
        for cue in cues.sorted(by: { $0.start < $1.start }) {
            guard let name = sectionName(for: cue.text),
                  let start = measureStarts.first(where: { $0 >= cue.end - barLineTolerance }),
                  songDuration <= 0 || start < songDuration else { continue }
            if named.last?.name == name { continue }
            if let last = named.last, start <= last.start {
                named[named.count - 1] = (last.start, name)
                continue
            }
            named.append((start, name))
        }
        guard !named.isEmpty else { return [] }

        // The opening before the first call belongs to the first section.
        named[0].start = 0

        var totals: [String: Int] = [:]
        for section in named { totals[section.name, default: 0] += 1 }
        var seen: [String: Int] = [:]
        return named.enumerated().map { index, section in
            var name = section.name
            if numberedNames.contains(name), totals[name, default: 0] > 1 {
                seen[name, default: 0] += 1
                name += " \(seen[name]!)"
            }
            return ArrangementMarker(name: name, startSeconds: section.start, sortOrder: index)
        }
    }

    /// Bar line times across the song from its tempo map.
    static func measureStarts(
        tempoChanges: [TempoChange],
        timeSignatureChanges: [TimeSignatureChange],
        through duration: TimeInterval
    ) -> [TimeInterval] {
        var starts: [TimeInterval] = []
        var measure = 1
        while true {
            let time = MeasureTiming.timeAtStartOfMeasure(
                measure,
                tempoChanges: tempoChanges,
                timeSignatureChanges: timeSignatureChanges
            )
            guard time <= duration, starts.count < 10_000 else { break }
            if let last = starts.last, time <= last { break }
            starts.append(time)
            measure += 1
        }
        return starts
    }

    /// The guide's phrases, one per sentence ("Break. Interlude. All in." is three calls).
    /// Empty when speech recognition isn't available or the transcription fails.
    static func spokenCues(in urls: [URL]) async -> [SpokenCue] {
        guard OnDeviceTranscriber.isAvailable, !urls.isEmpty,
              let mix = try? await SongAnalysisAudio.mixedAsset(from: urls) else { return [] }
        defer { if let cleanupURL = mix.cleanupURL { try? FileManager.default.removeItem(at: cleanupURL) } }
        return sentences(from: await OnDeviceTranscriber.transcribe(mix.asset.url))
    }

    static func sentences(from runs: [OnDeviceTranscriber.TimedText]) -> [SpokenCue] {
        var cues: [SpokenCue] = []
        var current: SpokenCue?
        for run in runs {
            if current == nil {
                current = SpokenCue(start: run.start, end: run.end, text: "")
            }
            current?.text += run.text
            current?.end = run.end
            if run.text.contains(where: { ".!?".contains($0) }), let cue = current {
                cues.append(cue)
                current = nil
            }
        }
        if let current, !current.text.trimmingCharacters(in: .whitespaces).isEmpty {
            cues.append(current)
        }
        return cues
    }
}
