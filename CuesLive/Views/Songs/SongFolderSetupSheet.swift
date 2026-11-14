import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SongFolderSetupSession: Identifiable {
    let id = UUID()
    let previews: [SongFolderImporter.Preview]
}

struct SongFolderSetupSheet: View {
    let previews: [SongFolderImporter.Preview]
    let onFinish: ([SongFolderImporter.ImportRequest]) -> Void

    @FocusState private var songNameFocused: Bool

    @State private var index: Int
    @State private var songName: String
    @State private var bpmText: String
    @State private var selectedPreset: MeterPreset
    @State private var keySelection: String
    @State private var confirmed: [SongFolderImporter.ImportRequest] = []
    @State private var didFinish = false
    @State private var detectedBPMs: [UUID: Double] = [:]
    @State private var failedDetections: Set<UUID> = []
    /// The tempo text as loaded, so a detected tempo never overwrites one the user typed.
    @State private var loadedBPMText: String

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

    init(previews: [SongFolderImporter.Preview], onFinish: @escaping ([SongFolderImporter.ImportRequest]) -> Void) {
        self.previews = previews
        self.onFinish = onFinish
        let first = previews[0]
        _index = State(initialValue: 0)
        _songName = State(initialValue: first.suggestedName)
        let firstBPMText = Self.formatBPM(first.bpm ?? TempoChange.defaultBPM)
        _bpmText = State(initialValue: firstBPMText)
        _loadedBPMText = State(initialValue: firstBPMText)
        _selectedPreset = State(initialValue: Self.preset(for: first))
        _keySelection = State(initialValue: "")
    }

    private var currentPreview: SongFolderImporter.Preview {
        previews[index]
    }

    private var isLastSong: Bool {
        index >= previews.count - 1
    }

    private var meterPresets: [MeterPreset] {
        var presets = Self.standardPresets
        let detected = Self.preset(for: currentPreview)
        if !presets.contains(detected) {
            presets.insert(detected, at: 0)
        }
        if !presets.contains(selectedPreset) {
            presets.insert(selectedPreset, at: 0)
        }
        return presets
    }

    private var canContinue: Bool {
        !songName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parsedBPM != nil
            && !(isDetectingCurrentTempo && bpmText == loadedBPMText)
    }

    private func needsTempoDetection(_ preview: SongFolderImporter.Preview) -> Bool {
        preview.bpm == nil && SongTempoDetector.isAvailable
            && !SongTempoDetector.analysisURLs(fromStems: preview.trackURLs).isEmpty
    }

    private var isDetectingCurrentTempo: Bool {
        let id = currentPreview.id
        return needsTempoDetection(currentPreview) && detectedBPMs[id] == nil && !failedDetections.contains(id)
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
                    if previews.count > 1 {
                        Text("Song \(index + 1) of \(previews.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppColors.textTertiary)
                    }

                    labeledField("Song name") {
                        TextField("Song name", text: $songName)
                            .textFieldStyle(.roundedBorder)
                            .focused($songNameFocused)
                    }

                    labeledField("Tempo (BPM)") {
                        TextField("120", text: $bpmText)
                            .textFieldStyle(.roundedBorder)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
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

                    if let sourceNote {
                        Text(sourceNote)
                            .font(.caption)
                            .foregroundStyle(AppColors.textTertiary)
                    }
                }
                .padding(AppSpacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .formSheetFrame(minWidth: 380, minHeight: 360)
                .navigationTitle("Import Song")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            finish(includingCurrent: false)
                        }
                        .foregroundStyle(AppColors.textSecondary)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isLastSong ? "Add" : "Next") {
                            continueImport()
                        }
                        .foregroundStyle(canContinue ? AppColors.accent : AppColors.textTertiary)
                        .disabled(!canContinue)
                    }
                }
                .onAppear {
                    songNameFocused = true
                }
                .task {
                    await detectTempos()
                }
            }
        }
        .interactiveDismissDisabled(true)
    }

    private var sourceNote: String? {
        let preview = currentPreview
        if preview.bpm != nil || preview.timeSignatureNumerator != nil {
            return "Tempo and meter were read from the Ableton set."
        }
        if detectedBPMs[preview.id] != nil {
            return "Tempo was detected from the audio."
        }
        if failedDetections.contains(preview.id) {
            return "Couldn't detect a tempo. Enter it by hand."
        }
        return isDetectingCurrentTempo ? "Detecting tempo from the audio…" : nil
    }

    /// Fills each song's tempo from its stems when the folder has no Ableton set to read it from.
    /// Runs through every folder up front so later songs are ready by the time they're shown.
    private func detectTempos() async {
        for preview in previews where needsTempoDetection(preview) {
            let didAccess = preview.folderURL.startAccessingSecurityScopedResource()
            let bpm = try? await SongTempoDetector.detectBPM(
                from: SongTempoDetector.analysisURLs(fromStems: preview.trackURLs)
            )
            if didAccess {
                preview.folderURL.stopAccessingSecurityScopedResource()
            }
            guard !Task.isCancelled else { return }
            guard let bpm else {
                failedDetections.insert(preview.id)
                continue
            }
            detectedBPMs[preview.id] = bpm
            if preview.id == currentPreview.id, bpmText == loadedBPMText {
                bpmText = Self.formatBPM(bpm)
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

    private func continueImport() {
        guard let request = currentRequest() else { return }
        if isLastSong {
            finish(includingCurrent: true)
        } else {
            confirmed.append(request)
            index += 1
            loadPreview(previews[index])
            songNameFocused = true
        }
    }

    private func currentRequest() -> SongFolderImporter.ImportRequest? {
        guard let bpm = parsedBPM else { return nil }
        let name = songName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return SongFolderImporter.ImportRequest(
            folderURL: currentPreview.folderURL,
            settings: SongFolderImporter.ImportSettings(
                name: name,
                bpm: bpm,
                timeSignatureNumerator: selectedPreset.numerator,
                timeSignatureDenominator: selectedPreset.denominator,
                baseKeyRaw: keySelection.isEmpty ? nil : keySelection
            )
        )
    }

    private func finish(includingCurrent: Bool) {
        guard !didFinish else { return }
        didFinish = true
        var requests = confirmed
        if includingCurrent, let request = currentRequest() {
            requests.append(request)
        }
        onFinish(requests)
    }

    private func loadPreview(_ preview: SongFolderImporter.Preview) {
        songName = preview.suggestedName
        loadedBPMText = Self.formatBPM(preview.bpm ?? TempoChange.defaultBPM)
        bpmText = detectedBPMs[preview.id].map(Self.formatBPM) ?? loadedBPMText
        selectedPreset = Self.preset(for: preview)
        keySelection = ""
    }

    private static func preset(for preview: SongFolderImporter.Preview) -> MeterPreset {
        let numerator = preview.timeSignatureNumerator ?? TimeSignatureChange.defaultNumerator
        let denominator = preview.timeSignatureDenominator ?? TimeSignatureChange.defaultDenominator
        guard (1...32).contains(numerator), TimeSignatureChange.validDenominators.contains(denominator) else {
            return MeterPreset(
                numerator: TimeSignatureChange.defaultNumerator,
                denominator: TimeSignatureChange.defaultDenominator
            )
        }
        return MeterPreset(numerator: numerator, denominator: denominator)
    }

    private static func formatBPM(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.05 {
            return String(Int(value.rounded()))
        }
        return String(format: "%.1f", value)
    }
}
