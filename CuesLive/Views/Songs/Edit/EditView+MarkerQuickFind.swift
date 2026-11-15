import SwiftUI

extension EditView {
    @ViewBuilder
    var markerQuickFindOverlay: some View {
        if let markerQuickFind {
            MarkerQuickFindView(find: markerQuickFind, sections: displaySections, onChoose: chooseQuickFind)
                .padding(.top, TimelineLayout.topRulerHeight + AppSpacing.lg)
        }
    }

    /// Typing over the timeline opens the marker finder; once open it takes every key it understands.
    func handleMarkerQuickFindKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard isTimelineFocused else { return .ignored }
        guard var find = markerQuickFind else {
            guard let opened = MarkerQuickFind.opening(with: press) else { return .ignored }
            markerQuickFind = opened
            return .handled
        }
        switch find.handle(press, sections: displaySections) {
        case .ignored:
            return .ignored
        case .handled:
            markerQuickFind = find
        case .dismiss:
            markerQuickFind = nil
        case .choose(let choice):
            chooseQuickFind(choice)
        }
        return .handled
    }

    private func chooseQuickFind(_ choice: MarkerQuickFind.Choice) {
        markerQuickFind = nil
        isTimelineFocused = true
        switch choice {
        case .section(let section):
            goToSection(section)
        case .add(let name):
            addSection(at: audioEngine.isPlaying ? audioEngine.currentTime : playbackStart, named: name)
        }
    }

    /// While playing, the section is cued like a click on the ruler; stopped, the edit point moves there.
    private func goToSection(_ section: SongSection) {
        if audioEngine.isPlaying {
            cueSection(section)
            return
        }
        insertionTime = section.timelineStartSeconds
        editSelection = nil
        if !viewModel.followsSetlist {
            audioEngine.seek(to: section.timelineStartSeconds)
        }
    }
}
