import SwiftUI

/// Lives in the tab bar's accessory slot. Deliberately doesn't read the playhead, so it never
/// re-renders while audio plays.
struct MiniPlayer: View {
    let transition: Namespace.ID

    @Environment(AppModel.self) private var model
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        let player = model.player
        if let item = player.item {
            HStack(spacing: 12) {
                CoverView(source: item.coverSource, title: item.title, cornerRadius: 6)
                    .frame(width: 34, height: 34)
                    .matchedTransitionSource(id: "player", in: transition)

                VStack(alignment: .leading, spacing: 1) {
                    Text(player.currentChapter?.title ?? player.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if placement != .inline {
                        Text(item.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    player.togglePlayPause()
                } label: {
                    Group {
                        if player.isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .font(.title3)
                    .frame(width: 34, height: 34)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                if placement != .inline {
                    Button {
                        player.skip(by: model.settings.skipForward)
                    } label: {
                        Image(systemName: SkipSymbol.forward(model.settings.skipForward))
                            .font(.title3)
                            .frame(width: 34, height: 34)
                    }
                    .accessibilityLabel("Skip forward \(Int(model.settings.skipForward)) seconds")
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .contentShape(.rect)
            .onTapGesture { model.presentingPlayer = true }
            .accessibilityAction(named: "Open player") { model.presentingPlayer = true }
        }
    }
}
