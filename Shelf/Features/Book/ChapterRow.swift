import SwiftUI

struct ChapterRow: View {
    enum State { case played, current, upcoming }

    let chapter: Chapter
    let number: Int
    let state: State
    var isPlaying = false
    var onDark = false

    static func state(index: Int, current: Int?) -> State {
        guard let current else { return .upcoming }
        if index < current { return .played }
        if index == current { return .current }
        return .upcoming
    }

    var body: some View {
        HStack(spacing: 14) {
            leading
                .frame(width: 22)
            Text(chapter.title)
                .font(.body)
                .fontWeight(state == .current ? .semibold : .regular)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(Format.clock(chapter.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(secondary)
        }
        .foregroundStyle(primary)
        .padding(.vertical, 13)
        .contentShape(.rect)
        .overlay(alignment: .bottom) {
            Rectangle().fill(onDark ? .white.opacity(0.08) : Color.primary.opacity(0.07)).frame(height: 0.5)
                .padding(.leading, 36)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(state == .played ? "Played" : state == .current ? "Current chapter" : "")
    }

    @ViewBuilder private var leading: some View {
        switch state {
        case .played:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(secondary)
        case .current:
            // Static on purpose: a looping animation here would redraw every frame while playing.
            Image(systemName: isPlaying ? "speaker.wave.2.fill" : "play.circle.fill")
                .foregroundStyle(Color.accentColor)
        case .upcoming:
            Text("\(number)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(secondary)
        }
    }

    private var primary: Color {
        switch state {
        case .current: .accentColor
        case .played: onDark ? .white.opacity(0.55) : .secondary
        case .upcoming: onDark ? .white : .primary
        }
    }

    private var secondary: Color { onDark ? .white.opacity(0.5) : .secondary }
}
