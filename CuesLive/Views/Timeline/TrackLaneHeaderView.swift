import SwiftUI

struct TrackLaneHeaderView: View {
    @Bindable var track: AudioTrack
    @Bindable private var audioEngine = AudioEngineManager.shared
    let laneHeight: CGFloat
    let isSelected: Bool
    let groups: [TrackGroup]
    let onSelect: (PointerModifiers) -> Void
    let onMixChange: () -> Void
    /// How many tracks a group assignment from this header moves: the whole selection when this
    /// track is part of it, otherwise just this track.
    let groupTargetCount: Int
    let onAssignGroup: (TrackGroup?) -> Void
    let onManageGroups: () -> Void
    let onRename: () -> Void
    /// While true the name is an editable field; Return or clicking away keeps the new name, Esc drops it.
    let isRenaming: Bool
    @Binding var renameText: String
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onBatchRename: () -> Void
    let onDelete: () -> Void
    /// Drag distance downward from the press, in points.
    let onResize: (CGFloat) -> Void
    let onResizeEnded: () -> Void

    @FocusState private var isNameFieldFocused: Bool

    private var trackColors: (header: Color, body: Color) {
        TrackGroupPalette.colors(for: track.group)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            nameLabel

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    TrackMixButton(
                        label: "M",
                        isActive: track.isMuted,
                        activeColor: .dawMuteActive
                    ) {
                        track.isMuted.toggle()
                        onMixChange()
                    }

                    TrackMixButton(
                        label: "S",
                        isActive: track.isSolo,
                        activeColor: .dawSoloActive
                    ) {
                        track.isSolo.toggle()
                        onMixChange()
                    }

                    TrackVolumeField(
                        volume: $track.volume,
                        onLiveChange: applyLiveMix,
                        onEditingEnded: onMixChange
                    )

                    TrackPanField(
                        pan: $track.pan,
                        onLiveChange: applyLiveMix,
                        onEditingEnded: onMixChange
                    )
                }

                groupPicker
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
        .frame(width: TimelineLayout.trackHeaderWidth, height: laneHeight, alignment: .topLeading)
        .clipped()
        .background {
            if isSelected {
                Rectangle()
                    .fill(Color.dawTrackHeaderSelected)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Rename") {
                onRename()
            }
            if groupTargetCount > 1 {
                Button("Batch Rename \(groupTargetCount) Tracks…") {
                    onBatchRename()
                }
            }
            Menu(groupTargetCount > 1 ? "Move \(groupTargetCount) Tracks to Group" : "Move to Group") {
                groupOptions
            }
            Button("Delete", role: .destructive) {
                onDelete()
            }
        }
        .onTapGesture { onSelect(.current) }
        .overlay(alignment: .bottom) {
            TrackLaneResizeHandle(onChanged: onResize, onEnded: onResizeEnded)
                .frame(maxWidth: .infinity)
                .frame(height: 6)
                .offset(y: 2)
        }
    }

    @ViewBuilder
    private var nameLabel: some View {
        if isRenaming {
            TextField("Track name", text: $renameText)
                .textFieldStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppColors.textPrimary)
                .focused($isNameFieldFocused)
                .onSubmit(onCommitRename)
                .onKeyPress(.escape) {
                    onCancelRename()
                    return .handled
                }
                .onAppear { isNameFieldFocused = true }
                .onChange(of: isNameFieldFocused) { _, focused in
                    if !focused { onCommitRename() }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.dawMixButtonBackground)
        } else {
            Text(track.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? AppColors.textPrimary : AppColors.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture(count: 2).onEnded { onRename() })
        }
    }

    private func applyLiveMix() {
        audioEngine.applyLiveTrackMix(id: track.id, volume: Float(track.volume), pan: Float(track.pan))
    }

    @ViewBuilder
    private var groupOptions: some View {
        Button("No Group") {
            onAssignGroup(nil)
        }

        ForEach(groups) { group in
            Button(group.name) {
                onAssignGroup(group)
            }
        }

        Divider()

        Button("Manage Groups…") {
            onManageGroups()
        }
    }

    private var groupPicker: some View {
        Menu {
            groupOptions
        } label: {
            HStack(spacing: 4) {
                Text(track.group?.name ?? "No Group")
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.caption2)
            .foregroundStyle(trackColors.body)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.dawMixButtonBackground)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(FlexibleControlSizing())
    }
}

private struct FlexibleControlSizing: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.buttonSizing(.flexible)
        } else {
            content
        }
    }
}
