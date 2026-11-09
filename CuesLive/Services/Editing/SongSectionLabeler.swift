import Foundation

/// What the labeler knows about one detected section.
struct SectionProfile: Equatable {
    var start: TimeInterval
    var end: TimeInterval
    /// Share of the section where the analysis hears a voice, 0...1.
    var vocalCoverage: Double
    /// Mean level of the section in dB.
    var loudness: Double
    /// Words transcribed inside the section, lowercased. Empty when there are no lyrics to go on.
    var words: [String] = []

    var duration: TimeInterval { end - start }
}

/// Names detected sections from the shape most songs share, with no network or model of its own.
///
/// Sections with no voice at the edges are the intro and outro. Sections are grouped into parts
/// when their chords and melody line up or their lyrics repeat. The loudest part that comes back
/// after something else and is first heard in the first half is the chorus, the sung parts before
/// it are verses, a part that always leads into the chorus is the pre-chorus, and a sung part
/// first heard after the second chorus is the bridge.
enum SongSectionLabeler {
    struct Label: Equatable {
        var start: TimeInterval
        var name: String
    }

    /// A section counts as sung when the voice covers at least this much of it.
    static let vocalThreshold = 0.3
    /// Two sections are the same part when they match at least this well, 0...1.
    static let repeatThreshold: Float = 0.5
    /// Instrumental sections shorter than this between sung parts are turnarounds.
    static let turnaroundMaxDuration: TimeInterval = 10
    /// Lyrics are compared only when both sections have at least this many word pairs.
    static let minimumWordPairs = 3
    /// A loud neighbor joins the chorus when it matches a chorus section at least this well.
    static let chorusNeighborThreshold: Float = 0.45
    /// Sections at the edges this many dB under the typical sung level are intro or outro.
    static let edgeQuietness = 5.0
    /// Below this many transcribed words the lyrics say nothing about where the song starts.
    static let minimumSongWords = 30
    /// With lyrics available, an edge section without words must be at least this sung to count.
    static let clearlySungCoverage = 0.6

    private static let numberedNames: Set<String> = ["Verse", "Pre-Chorus", "Chorus", "Bridge"]

    /// Labels in song order with neighbors of the same part merged, or nil when nothing is sung.
    ///
    /// - Parameter audioSimilarity: How alike each pair of sections sounds, 0...1, indexed like `sections`.
    static func label(_ sections: [SectionProfile], audioSimilarity: [[Float]]) -> [Label]? {
        guard let names = baseNames(sections, audioSimilarity: audioSimilarity) else { return nil }

        var merged: [Label] = []
        for (index, name) in names.enumerated() where merged.last?.name != name {
            merged.append(Label(start: sections[index].start, name: name))
        }

        var totals: [String: Int] = [:]
        for label in merged { totals[label.name, default: 0] += 1 }
        var seen: [String: Int] = [:]
        return merged.map { label in
            guard numberedNames.contains(label.name), totals[label.name, default: 0] > 1 else { return label }
            seen[label.name, default: 0] += 1
            return Label(start: label.start, name: "\(label.name) \(seen[label.name]!)")
        }
    }

    /// One unnumbered name per section, before neighbors are merged.
    static func baseNames(_ sections: [SectionProfile], audioSimilarity: [[Float]]) -> [String]? {
        let sung = sections.map { $0.vocalCoverage >= vocalThreshold }
        let sungLoudness = sections.indices.filter { sung[$0] }.map { sections[$0].loudness }
        guard !sungLoudness.isEmpty else { return nil }
        let typicalLoudness = median(sungLoudness)
        let hasLyrics = sections.reduce(0) { $0 + $1.words.count } >= minimumSongWords

        // The song proper starts at the first section that is sung, not much quieter than the rest,
        // and, when there are lyrics, has words in it or is clearly sung. The same holds from the end.
        func isEdge(_ index: Int) -> Bool {
            let section = sections[index]
            return !sung[index]
                || section.loudness < typicalLoudness - edgeQuietness
                || (hasLyrics && section.words.isEmpty && section.vocalCoverage < clearlySungCoverage)
        }
        var firstSung = 0
        while firstSung < sections.count, isEdge(firstSung) { firstSung += 1 }
        var lastSung = sections.count - 1
        while lastSung > firstSung, isEdge(lastSung) { lastSung -= 1 }
        guard firstSung < sections.count else { return nil }

        var names = [String](repeating: "", count: sections.count)
        for index in sections.indices where index < firstSung { names[index] = "Intro" }
        for index in sections.indices where index > lastSung { names[index] = "Outro" }
        for index in firstSung...lastSung where !sung[index] {
            names[index] = sections[index].duration < turnaroundMaxDuration ? "Turnaround" : "Instrumental"
        }

        let sungIndices = (firstSung...lastSung).filter { sung[$0] }
        let similarities = sungIndices.map { i in
            sungIndices.map { j in
                i == j ? 1 : max(audioSimilarity[i][j], lyricSimilarity(sections[i].words, sections[j].words))
            }
        }
        let clusterIDs = clusters(similarities, threshold: repeatThreshold)
        var clusterOf: [Int: Int] = [:]
        for (position, index) in sungIndices.enumerated() { clusterOf[index] = clusterIDs[position] }
        let members = Dictionary(grouping: sungIndices) { clusterOf[$0]! }

        let sungStart = sections[firstSung].start
        let midpoint = sungStart + (sections[lastSung].end - sungStart) / 2

        // A part "comes back" when it is heard again after something else; neighbors are one occurrence.
        func occurrences(_ indices: [Int]) -> [Int] {
            indices.sorted().filter { !indices.contains($0 - 1) }
        }
        func chorusScore(_ indices: [Int]) -> Double {
            let loudness = indices.map { sections[$0].loudness }.reduce(0, +) / Double(indices.count)
            return loudness - typicalLoudness + 0.5 * Double(occurrences(indices).count)
        }
        let chorusCluster = members
            .filter { occurrences($0.value).count >= 2 && sections[$0.value.min()!].start < midpoint }
            .max { lhs, rhs in
                let (left, right) = (chorusScore(lhs.value), chorusScore(rhs.value))
                return left != right ? left < right : lhs.key > rhs.key
            }?
            .key

        guard let chorusCluster else {
            // Nothing comes back: the loud sung parts are the chorus, the rest are verses.
            for index in sungIndices {
                names[index] = sections[index].loudness >= typicalLoudness + 1.5 ? "Chorus" : "Verse"
            }
            return names
        }

        // Detected boundaries often split a chorus; a loud neighbor that sounds like the chorus belongs to it.
        var choruses = Set(members[chorusCluster]!)
        var grew = true
        while grew {
            grew = false
            for index in sungIndices where !choruses.contains(index)
                && (choruses.contains(index - 1) || choruses.contains(index + 1))
                && sections[index].loudness >= typicalLoudness - 1 {
                let likeness = choruses.map { max(audioSimilarity[index][$0], lyricSimilarity(sections[index].words, sections[$0].words)) }.max() ?? 0
                if likeness >= chorusNeighborThreshold {
                    choruses.insert(index)
                    grew = true
                }
            }
        }
        let chorusStarts = occurrences(Array(choruses))
        let firstChorus = chorusStarts[0]
        let secondChorus = chorusStarts.count > 1 ? chorusStarts[1] : nil

        // A pre-chorus comes back, always sits right before a chorus, and always follows another sung part.
        let preChorusClusters = Set(members.compactMap { id, indices -> Int? in
            guard id != chorusCluster, occurrences(indices).count >= 2 else { return nil }
            let fits = indices.allSatisfy { index in
                index > 0 && choruses.contains(index + 1) && sung[index - 1]
                    && !choruses.contains(index - 1) && clusterOf[index - 1] != id
            }
            return fits ? id : nil
        })
        // Verses are the sung parts heard before the first chorus.
        let verseClusters = Set(sungIndices.filter { $0 < firstChorus }.map { clusterOf[$0]! })
            .subtracting(preChorusClusters)

        for index in sungIndices {
            let id = clusterOf[index]!
            if choruses.contains(index) {
                names[index] = "Chorus"
            } else if preChorusClusters.contains(id) {
                names[index] = "Pre-Chorus"
            } else if verseClusters.contains(id) {
                names[index] = "Verse"
            } else if index > (secondChorus ?? firstChorus), sections[index].start >= midpoint {
                names[index] = "Bridge"
            } else {
                names[index] = "Verse"
            }
        }
        return names
    }

    /// Share of the shorter section's word pairs that also appear in the other, 0...1.
    static func lyricSimilarity(_ a: [String], _ b: [String]) -> Float {
        let pairsA = wordPairs(a), pairsB = wordPairs(b)
        let smaller = min(pairsA.count, pairsB.count)
        guard smaller >= minimumWordPairs else { return 0 }
        return Float(pairsA.intersection(pairsB).count) / Float(smaller)
    }

    /// Average-linkage grouping: keeps joining the two most alike groups while they stay above the threshold.
    static func clusters(_ similarities: [[Float]], threshold: Float) -> [Int] {
        var groups = similarities.indices.map { [$0] }
        while groups.count > 1 {
            var best: (x: Int, y: Int, score: Float)?
            for x in groups.indices {
                for y in groups.indices where y > x {
                    var total: Float = 0
                    for i in groups[x] { for j in groups[y] { total += similarities[i][j] } }
                    let score = total / Float(groups[x].count * groups[y].count)
                    if score > best?.score ?? -.infinity { best = (x, y, score) }
                }
            }
            guard let best, best.score >= threshold else { break }
            groups[best.x] += groups[best.y]
            groups.remove(at: best.y)
        }
        var ids = [Int](repeating: 0, count: similarities.count)
        for (id, group) in groups.enumerated() { for index in group { ids[index] = id } }
        return ids
    }

    private static func wordPairs(_ words: [String]) -> Set<String> {
        guard words.count > 1 else { return [] }
        return Set((1..<words.count).map { "\(words[$0 - 1]) \(words[$0])" })
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
