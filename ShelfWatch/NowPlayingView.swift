import SwiftUI

struct NowPlayingView: View {
    @Environment(WatchRemote.self) private var remote
    @State private var choosingSleepTimer = false

    var body: some View {
        NavigationStack {
            Group {
                if let snapshot = remote.snapshot {
                    playing(snapshot)
                } else {
                    ContentUnavailableView("Nothing Playing", systemImage: "books.vertical",
                                           description: Text("Start a book in Shelf on your iPhone."))
                }
            }
            .navigationTitle("Shelf")
            .toolbar {
                if let snapshot = remote.snapshot {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            choosingSleepTimer = true
                        } label: {
                            Image(systemName: snapshot.sleep == .off ? "moon.zzz" : "moon.zzz.fill")
                                .foregroundStyle(.white)
                        }
                        .accessibilityLabel("Sleep timer")
                    }
                }
            }
            .sheet(isPresented: $choosingSleepTimer) {
                SleepTimerOptions(hasChapters: (remote.snapshot?.chapterCount ?? 0) > 0,
                                  isSet: remote.snapshot?.sleep != .off) { command in
                    remote.send(command)
                    choosingSleepTimer = false
                }
            }
        }
        .tint(.accentColor)
    }

    private func playing(_ snapshot: NowPlayingSnapshot) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Group {
                    if let cover = remote.cover {
                        Image(uiImage: cover).resizable().scaledToFill()
                    } else {
                        Color.accentColor.opacity(0.4).overlay { Image(systemName: "book.closed.fill") }
                    }
                }
                .frame(width: 34, height: 34)
                .clipShape(.rect(cornerRadius: 6))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(snapshot.chapterTitle ?? snapshot.title)
                        .font(.headline)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    Text(snapshot.chapterTitle == nil ? (snapshot.subtitle ?? "") : snapshot.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ChapterProgressRow(snapshot: snapshot)

            HStack {
                transportButton("backward.end.fill", label: "Previous chapter", size: 15) { remote.send(.previousChapter) }
                Spacer(minLength: 0)
                transportButton(SkipSymbol.backward(snapshot.skipBackward), label: "Skip back", size: 20) { remote.send(.skipBack) }
                Spacer(minLength: 0)
                Button {
                    remote.send(.togglePlayback)
                } label: {
                    Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 46, height: 46)
                        .background(Color.accentColor, in: .circle)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(snapshot.isPlaying ? "Pause" : "Play")
                Spacer(minLength: 0)
                transportButton(SkipSymbol.forward(snapshot.skipForward), label: "Skip forward", size: 20) { remote.send(.skipForward) }
                Spacer(minLength: 0)
                transportButton("forward.end.fill", label: "Next chapter", size: 15) { remote.send(.nextChapter) }
            }
            .padding(.top, 2)

            if let problem = remote.problem {
                Text(problem)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 4)
    }

    private func transportButton(_ symbol: String, label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: 30, height: 40)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Chapter progress and time left, animated by the system from dates while playing.
private struct ChapterProgressRow: View {
    let snapshot: NowPlayingSnapshot

    var body: some View {
        VStack(spacing: 2) {
            if snapshot.isPlaying {
                ProgressView(timerInterval: snapshot.chapterDates, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
            } else {
                ProgressView(value: snapshot.isFinished ? 1 : snapshot.chapterFraction(at: .now))
            }
            HStack {
                if let number = snapshot.chapterNumber, let count = snapshot.chapterCount, count > 1 {
                    Text("\(number) of \(count)")
                }
                Spacer()
                SleepLabel(sleep: snapshot.sleep)
                if snapshot.isPlaying {
                    Text(timerInterval: snapshot.chapterDates, countsDown: true)
                } else if !snapshot.isFinished {
                    Text(Format.clock(snapshot.chapterRemaining(at: snapshot.capturedAt)))
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .tint(.accentColor)
    }
}

private struct SleepLabel: View {
    let sleep: SleepSnapshot

    var body: some View {
        switch sleep {
        case .off:
            EmptyView()
        case .endOfChapter:
            Image(systemName: "moon.zzz.fill").foregroundStyle(Color.accentColor)
        case let .running(endsAt):
            Label {
                Text(timerInterval: Date.now...max(endsAt, .now), countsDown: true)
            } icon: {
                Image(systemName: "moon.zzz.fill")
            }
            .labelStyle(.titleAndIcon)
            .foregroundStyle(Color.accentColor)
        case let .paused(remaining):
            Label(Format.clock(remaining), systemImage: "moon.zzz")
        }
    }
}

private struct SleepTimerOptions: View {
    let hasChapters: Bool
    let isSet: Bool
    let choose: (WatchCommand) -> Void

    var body: some View {
        List {
            if isSet {
                Button("Turn Off", systemImage: "xmark") { choose(.sleepOff) }
            }
            if hasChapters {
                Button("End of Chapter", systemImage: "book.pages") { choose(.sleepEndOfChapter) }
            }
            ForEach([WatchCommand.sleep15, .sleep30, .sleep45, .sleep60], id: \.self) { command in
                Button("\(Int(command.sleepMinutes ?? 0)) minutes") { choose(command) }
            }
        }
        .navigationTitle("Sleep Timer")
    }
}
