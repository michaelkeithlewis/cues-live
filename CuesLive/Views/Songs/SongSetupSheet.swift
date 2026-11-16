import SwiftData
import SwiftUI

/// Name, opening tempo, time signature and key for a song in the library. Imports fill these in
/// on their own; this is where they get corrected.
struct SongSetupSheet: View {
    let song: Song
    let onFinish: (Error?) -> Void

    @Environment(\.modelContext) private var modelContext
    @FocusState private var songNameFocused: Bool

    @State private var songName: String
    @State private var bpmText: String
    @State private var selectedPreset: MeterPreset
    @State var keySelection: String
    @State var keyMode: SongKeyMode
    @State var keyDetection: KeyDetectionState = .idle
    @State var keyDetectionTask: Task<Void, Never>?
    @State private var isDetectingTempo = false
    @State private var tempoNote: String?

    private struct MeterPreset: Hashable {
        let numerator: Int
        let denominator: Int

        var label: String { "\(numerator)/\(denominator)" }
    }

    private static let standardPresets: [MeterPreset] = [
        MeterPreset(numerator: 4, denominator: 4),
        MeterPreset(numerator: 3, denominator: 4),
        MeterPreset(numerator: 2, denominator: 4),
        MeterPreset(numerator: 6, denominator: 8),
        MeterPreset(numerator: 5, denominator: 4),
        MeterPreset(numerator: 7, denominator: 8),
        MeterPreset(numerator: 12, denominator: 8)
    ]

    private static let tempoFieldWidth: CGFloat = 72

    init(song: Song, onFinish: @escaping (Error?) -> Void) {
        self.song = song
        self.onFinish = onFinish
        let state = SongProjectBridge.projectStateOrDefaults(for: song)
        let tempo = state.tempoChanges.normalizedEnsuringInitialMarker(
            defaultBPM: song.bpm ?? TempoChange.defaultBPM
        )
        let meter = state.timeSignatureChanges.normalizedEnsuringInitialMarker(
            defaultNumerator: song.timeSignatureNumerator ?? TimeSignatureChange.defaultNumerator,
            defaultDenominator: song.timeSignatureDenominator ?? TimeSignatureChange.defaultDenominator
        )
        _songName = State(initialValue: song.name)
        _bpmText = State(initialValue: Self.formatBPM(tempo.referenceBPM))
        _selectedPreset = State(initialValue: MeterPreset(
            numerator: meter.referenceNumerator,
            denominator: meter.referenceDenominator
        ))
        _keySelection = State(initialValue: song.baseKeyRaw ?? "")
        _keyMode = State(initialValue: SongKeyMode(raw: song.keyModeRaw))
    }

    private var meterPresets: [MeterPreset] {
        var presets = Self.standardPresets
        if !presets.contains(selectedPreset) {
            presets.insert(selectedPreset, at: 0)
        }
        return presets
    }

    /// The song's instrument audio, without click or guide tracks.
    var analysisURLs: [URL] {
        SongSectionDetector.analysisTracks(in: song).compactMap { FileStore.trackURL(for: song, track: $0) }
    }

    private var canSave: Bool {
        !songName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parsedBPM != nil
    }

    private var parsedBPM: Double? {
        let sanitized = bpmText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(sanitized), value > 0, value.isFinite else {
            return nil
        }
        return min(
            max(value, TempoChange.validBPMRange.lowerBound),
            TempoChange.validBPMRange.upperBound
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                songSection
                timingSection
                keySection
            }
            .formStyle(.grouped)
            .navigationTitle("Song Setup")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        onFinish(nil)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!canSave)
                }
            }
            .onAppear {
                songNameFocused = true
            }
        }
        .standardDialogToolbar()
        .formSheetFrame(minWidth: 420, minHeight: 440)
        .onDisappear(perform: cancelKeyDetection)
    }

    private var songSection: some View {
        Section {
            TextField("Name", text: $songName, prompt: Text("Song name"))
                .focused($songNameFocused)
        }
    }

    private var timingSection: some View {
        Section {
            LabeledContent("Tempo") {
                HStack(spacing: AppSpacing.xs) {
                    TextField("Tempo", text: $bpmText, prompt: Text("120"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(maxWidth: Self.tempoFieldWidth)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                    Text("BPM")
                        .foregroundStyle(.secondary)
                }
            }
            if SongTempoDetector.isAvailable {
                HStack {
                    Button(action: detectTempo) {
                        Label("Detect Tempo", systemImage: "metronome")
                    }
                    .disabled(isDetectingTempo || analysisURLs.isEmpty)
                    Spacer()
                    if isDetectingTempo {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            Picker("Time Signature", selection: $selectedPreset) {
                ForEach(meterPresets, id: \.self) { preset in
                    Text(preset.label).tag(preset)
                }
            }
        } footer: {
            if let tempoNote {
                Text(tempoNote)
            }
        }
    }

    private func detectTempo() {
        let urls = analysisURLs
        isDetectingTempo = true
        tempoNote = nil
        Task {
            defer { isDetectingTempo = false }
            do {
                bpmText = Self.formatBPM(try await SongTempoDetector.detectBPM(from: urls))
                tempoNote = "Detected from the stems. You can still change it."
            } catch {
                tempoNote = error.localizedDescription
            }
        }
    }

    private func save() {
        guard let bpm = parsedBPM else { return }
        cancelKeyDetection()
        let settings = SongFolderImporter.sanitized(
            SongFolderImporter.ImportSettings(
                name: songName,
                bpm: bpm,
                timeSignatureNumerator: selectedPreset.numerator,
                timeSignatureDenominator: selectedPreset.denominator,
                baseKeyRaw: keySelection.isEmpty ? nil : keySelection,
                keyModeRaw: keySelection.isEmpty ? nil : keyMode.storedRaw
            ),
            fallbackName: song.name
        )
        do {
            try SongFolderImporter.applyImportSettings(settings, to: song, context: modelContext)
            try modelContext.save()
            onFinish(nil)
        } catch {
            onFinish(error)
        }
    }

    private static func formatBPM(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.05 {
            return String(Int(value.rounded()))
        }
        return String(format: "%.1f", value)
    }
}
