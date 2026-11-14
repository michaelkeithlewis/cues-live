import SwiftData
import SwiftUI

/// Name, opening tempo, meter and key for a song in the library. Imports fill these in on their own;
/// this is where they get corrected.
struct SongSetupSheet: View {
    let song: Song
    let onFinish: (Error?) -> Void

    @Environment(\.modelContext) private var modelContext

    @State private var songName: String
    @State private var bpmText: String
    @State private var selectedPreset: MeterPreset
    @State private var keySelection: String
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
    }

    private var meterPresets: [MeterPreset] {
        var presets = Self.standardPresets
        if !presets.contains(selectedPreset) {
            presets.insert(selectedPreset, at: 0)
        }
        return presets
    }

    private var analysisURLs: [URL] {
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
        AppSheetContainer {
            NavigationStack {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    labeledField("Song name") {
                        TextField("Song name", text: $songName)
                            .textFieldStyle(.roundedBorder)
                    }

                    labeledField("Tempo (BPM)") {
                        HStack(spacing: AppSpacing.sm) {
                            TextField("120", text: $bpmText)
                                .textFieldStyle(.roundedBorder)
                                #if os(iOS)
                                .keyboardType(.decimalPad)
                                #endif
                            if SongTempoDetector.isAvailable {
                                Button(isDetectingTempo ? "Detecting…" : "Detect") {
                                    detectTempo()
                                }
                                .disabled(isDetectingTempo || analysisURLs.isEmpty)
                            }
                        }
                    }

                    labeledField("Meter") {
                        Picker("Meter", selection: $selectedPreset) {
                            ForEach(meterPresets, id: \.self) { preset in
                                Text(preset.label).tag(preset)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    labeledField("Key") {
                        Picker("Key", selection: $keySelection) {
                            Text("None").tag("")
                            ForEach(SongMusicalKey.chromaticOrder, id: \.rawValue) { key in
                                Text(key.displayName).tag(key.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    if let tempoNote {
                        Text(tempoNote)
                            .font(.caption)
                            .foregroundStyle(AppColors.textTertiary)
                    }
                }
                .padding(AppSpacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .formSheetFrame(minWidth: 380, minHeight: 360)
                .navigationTitle("Song Setup")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            onFinish(nil)
                        }
                        .foregroundStyle(AppColors.textSecondary)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save", action: save)
                            .foregroundStyle(canSave ? AppColors.accent : AppColors.textTertiary)
                            .disabled(!canSave)
                    }
                }
            }
        }
    }

    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppColors.textSecondary)
            content()
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
                tempoNote = "Tempo was detected from the audio."
            } catch {
                tempoNote = error.localizedDescription
            }
        }
    }

    private func save() {
        guard let bpm = parsedBPM else { return }
        let settings = SongFolderImporter.sanitized(
            SongFolderImporter.ImportSettings(
                name: songName,
                bpm: bpm,
                timeSignatureNumerator: selectedPreset.numerator,
                timeSignatureDenominator: selectedPreset.denominator,
                baseKeyRaw: keySelection.isEmpty ? nil : keySelection
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
