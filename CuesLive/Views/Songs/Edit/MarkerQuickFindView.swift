import SwiftUI

/// The typed text and its choices, drawn over the top of the timeline.
struct MarkerQuickFindView: View {
    let find: MarkerQuickFind
    let sections: [SongSection]
    let onChoose: (MarkerQuickFind.Choice) -> Void

    var body: some View {
        let choices = find.choices(in: sections)
        let highlighted = find.highlightedIndex(in: sections)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AppSpacing.xs) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppColors.textTertiary)
                Text(find.text)
                    .foregroundStyle(AppColors.textPrimary)
                Spacer(minLength: 0)
                Text("Return to choose, Esc to close")
                    .font(.caption2)
                    .foregroundStyle(AppColors.textTertiary)
            }
            .padding(AppSpacing.sm)

            if !choices.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(choices.enumerated()), id: \.element) { index, choice in
                            row(for: choice, isHighlighted: index == highlighted)
                                .contentShape(Rectangle())
                                .onTapGesture { onChoose(choice) }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .lineLimit(1)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous).strokeBorder(AppColors.paneDivider))
        .shadow(radius: 12, y: 4)
    }

    private func row(for choice: MarkerQuickFind.Choice, isHighlighted: Bool) -> some View {
        HStack(spacing: AppSpacing.sm) {
            switch choice {
            case .section(let section):
                Image(systemName: "arrow.right.to.line")
                    .foregroundStyle(AppColors.textTertiary)
                Text(section.name)
            case .add(let name):
                Image(systemName: "plus")
                    .foregroundStyle(AppColors.accent)
                Text("Add “\(name)” here")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, 5)
        .background(isHighlighted ? AppColors.accent.opacity(0.25) : Color.clear)
    }
}
