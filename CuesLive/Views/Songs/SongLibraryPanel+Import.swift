import SwiftUI
#if os(macOS)
import AppKit
#endif

extension SongLibraryPanel {
    var importProgressOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()

            VStack(spacing: AppSpacing.sm) {
                ProgressView()
                    .tint(AppColors.accent)
                Text(isPreparingFolderSetup ? "Reading song folder…" : "Importing song folder…")
                    .font(.headline)
                    .foregroundStyle(AppColors.textPrimary)
            }
            .padding(AppSpacing.xl)
            .background(AppColors.surfaceElevated, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        }
    }

    func presentFolderImporter() {
        guard !isBusy else { return }
        #if os(macOS)
        // SwiftUI `.fileImporter` often fails to present from a Menu. Use NSOpenPanel after
        // the menu finishes dismissing so Finder reliably appears.
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = false
            panel.prompt = "Import"
            panel.message = "Choose a song folder with stems (and an optional Ableton Live Set)."
            guard panel.runModal() == .OK, let folderURL = panel.url else { return }
            queueFolderImport([folderURL])
        }
        #else
        showingFolderImporter = true
        #endif
    }

    #if os(iOS)
    func handleFolderSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            songActionError = error.localizedDescription
        case .success(let urls):
            guard let folderURL = urls.first else { return }
            queueFolderImport([folderURL])
        }
    }
    #endif

    #if os(macOS)
    @ViewBuilder
    var folderDropHighlight: some View {
        if isTargetedForFolderDrop {
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .stroke(AppColors.accent, lineWidth: 2)
                .padding(AppSpacing.xs)
                .allowsHitTesting(false)
        }
    }

    /// Handles a Finder drag dropped onto the library: each dropped folder is imported as a new song.
    func performFolderDrop(_ providers: [NSItemProvider]) -> Bool {
        isTargetedForFolderDrop = false
        guard !providers.isEmpty, !isBusy else {
            return false
        }

        Task { @MainActor in
            let folderURLs = await SongFolderDrop.folderURLs(from: providers)
            guard !folderURLs.isEmpty else {
                songActionError = "Drop a folder containing audio files to add a song."
                return
            }
            queueFolderImport(folderURLs)
        }
        return true
    }
    #endif

    /// Imports take the folder's name and any Ableton tempo and meter as they are. Tempo detection
    /// runs after the import, and "Song Setup…" changes any of it later.
    private static func importRequest(for preview: SongFolderImporter.Preview) -> SongFolderImporter.ImportRequest {
        SongFolderImporter.ImportRequest(
            folderURL: preview.folderURL,
            settings: SongFolderImporter.ImportSettings(
                name: preview.suggestedName,
                bpm: preview.bpm ?? TempoChange.defaultBPM,
                timeSignatureNumerator: preview.timeSignatureNumerator ?? TimeSignatureChange.defaultNumerator,
                timeSignatureDenominator: preview.timeSignatureDenominator ?? TimeSignatureChange.defaultDenominator,
                baseKeyRaw: nil
            )
        )
    }

    private func queueFolderImport(_ folderURLs: [URL]) {
        guard !isBusy, !folderURLs.isEmpty else { return }

        isPreparingFolderSetup = true
        let urls = folderURLs
        Task { @MainActor in
            await Task.yield()
            defer { isPreparingFolderSetup = false }

            var requests: [SongFolderImporter.ImportRequest] = []
            var failures: [String] = []
            for url in urls {
                do {
                    let preview = try await Task.detached(priority: .userInitiated) {
                        try SongFolderImporter.previewFolder(at: url)
                    }.value
                    requests.append(Self.importRequest(for: preview))
                } catch {
                    failures.append(
                        urls.count == 1
                            ? error.localizedDescription
                            : "\(url.lastPathComponent): \(error.localizedDescription)"
                    )
                }
            }

            if !failures.isEmpty {
                songActionError = failures.joined(separator: "\n")
            }
            guard !requests.isEmpty else { return }
            onFoldersSelected(requests)
        }
    }
}
