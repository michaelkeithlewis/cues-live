import SwiftUI

/// Batch rename for the selected tracks, with a live before-and-after list.
struct TrackBatchRenameSheet: View {
    let names: [String]
    let onCancel: () -> Void
    let onApply: ([String]) -> Void

    @State private var rename = TrackBatchRename()

    private var renamed: [String] {
        rename.rename(names)
    }

    var body: some View {
        AppSheetContainer {
            NavigationStack {
                Form {
                    Section {
                        Toggle("Replace", isOn: $rename.replaces)
                        if rename.replaces {
                            TextField("Find", text: $rename.find)
                            TextField("Replace with", text: $rename.replacement)
                            Toggle("Match case", isOn: $rename.matchesCase)
                        }
                    }
                    Section {
                        Toggle("Trim", isOn: $rename.trims)
                        if rename.trims {
                            Stepper("Remove \(rename.trimStart) from the start", value: $rename.trimStart, in: 0...64)
                            Stepper("Remove \(rename.trimEnd) from the end", value: $rename.trimEnd, in: 0...64)
                        }
                    }
                    Section {
                        Toggle("Add", isOn: $rename.adds)
                        if rename.adds {
                            TextField("Prefix", text: $rename.prefix)
                            TextField("Suffix", text: $rename.suffix)
                        }
                    }
                    Section {
                        Toggle("Number", isOn: $rename.numbers)
                        if rename.numbers {
                            Stepper("Start at \(rename.startNumber)", value: $rename.startNumber, in: 0...999)
                            Stepper("Count by \(rename.increment)", value: $rename.increment, in: 1...100)
                            Picker("Position", selection: $rename.numberPosition) {
                                ForEach(TrackBatchRename.NumberPosition.allCases) { position in
                                    Text(position.rawValue).tag(position)
                                }
                            }
                            .pickerStyle(.segmented)
                            TextField("Separator", text: $rename.separator)
                        }
                    }
                    Section("Preview") {
                        ForEach(Array(zip(names, renamed).enumerated()), id: \.offset) { _, pair in
                            HStack {
                                Text(pair.0)
                                    .foregroundStyle(AppColors.textSecondary)
                                Spacer()
                                Image(systemName: "arrow.right")
                                    .foregroundStyle(AppColors.textTertiary)
                                Spacer()
                                Text(pair.1)
                                    .foregroundStyle(pair.0 == pair.1 ? AppColors.textSecondary : AppColors.textPrimary)
                            }
                            .lineLimit(1)
                        }
                    }
                }
                .formStyle(.grouped)
                .formSheetFrame(minWidth: 460, minHeight: 520)
                .navigationTitle(names.count == 1 ? "Rename Track" : "Rename \(names.count) Tracks")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Rename") { onApply(renamed) }
                            .disabled(renamed == names)
                    }
                }
            }
        }
    }
}
