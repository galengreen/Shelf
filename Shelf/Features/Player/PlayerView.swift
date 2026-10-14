import AVKit
import MediaPlayer
import SwiftUI

struct PlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var palette: CoverPalette?
    @State private var showChapters = false
    @State private var bookmarkToast = false
    @State private var isLandscape = false

    /// iPad in landscape: artwork on the left, chapters and controls on the right.
    private var isTwoColumn: Bool { sizeClass == .regular && isLandscape }

    var body: some View {
        let player = model.player
        ZStack {
            MeshGradient(
                width: 3, height: 3,
                points: [[0, 0], [0.5, 0], [1, 0], [0, 0.45], [0.55, 0.5], [1, 0.4], [0, 1], [0.5, 1], [1, 1]],
                colors: palette?.meshColors ?? CoverPalette.fallbackMesh
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.6), value: palette)

            if let item = player.item {
                if isTwoColumn {
                    twoColumn(item)
                } else {
                    stacked(item)
                }
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { isLandscape = $0 }
        .overlay(alignment: .top) {
            if bookmarkToast {
                Label("Bookmark Added", systemImage: "bookmark.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.top, 92)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(1.6))
                        withAnimation(.smooth) { bookmarkToast = false }
                    }
            }
        }
        .foregroundStyle(.white)
        .tint(.white)
        .environment(\.colorScheme, .dark)
        .task(id: player.item?.id) {
            guard let item = player.item else { return }
            palette = await ImagePipeline.shared.palette(item.coverSource)
        }
        .onAppear { player.setTimeObservation(true) }
        .onDisappear { player.setTimeObservation(false) }
        .statusBarHidden(false)
    }

    /// The phone layout (also iPad in portrait, at a readable width).
    private func stacked(_ item: LibraryItem) -> some View {
        let player = model.player
        return VStack(spacing: 0) {
            DismissHandle { dismiss() }

            if showChapters {
                ListPanel(item: item) { showChapters = false }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                Artwork(item: item, isPlaying: player.isPlaying)
                    .frame(maxHeight: .infinity)
                    .transition(.opacity)
                if let next = player.suggestedNext {
                    UpNextCard(next: next)
                        .padding(.bottom, 18)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                } else {
                    TitleBlock(context: item.title,
                               title: player.currentChapter?.title ?? player.displayTitle,
                               chapterId: player.currentChapter?.id)
                        .padding(.bottom, 22)
                }
            }

            Scrubber()
                .padding(.bottom, 18)
            Transport()
                .padding(.bottom, 22)
            VolumeRow()
                .padding(.bottom, 18)
            BottomBar(showChapters: $showChapters, bookmarkAdded: $bookmarkToast)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 8)
        .animation(.smooth(duration: 0.35), value: showChapters)
        .animation(.smooth, value: player.suggestedNext?.id)
        .readableWidth(600)
    }

    private func twoColumn(_ item: LibraryItem) -> some View {
        let player = model.player
        return VStack(spacing: 0) {
            DismissHandle { dismiss() }
            HStack(spacing: 56) {
                Artwork(item: item, isPlaying: player.isPlaying, maxSide: 620)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 0) {
                    ListPanel(item: item, showsHeader: false) {}
                    if let next = player.suggestedNext {
                        UpNextCard(next: next)
                            .padding(.bottom, 18)
                    } else {
                        TitleBlock(context: item.title,
                                   title: player.currentChapter?.title ?? player.displayTitle,
                                   chapterId: player.currentChapter?.id)
                            .padding(.bottom, 18)
                    }
                    Scrubber()
                        .padding(.bottom, 14)
                    Transport()
                        .padding(.bottom, 18)
                    VolumeRow()
                        .padding(.bottom, 14)
                    BottomBar(showChapters: $showChapters, bookmarkAdded: $bookmarkToast, showsListToggle: false)
                }
                .frame(maxWidth: 520)
            }
            .padding(.horizontal, 56)
            .padding(.bottom, 16)
            .animation(.smooth, value: player.suggestedNext?.id)
        }
    }
}

private struct DismissHandle: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Capsule()
                .fill(.white.opacity(0.45))
                .frame(width: 40, height: 5)
                .frame(maxWidth: .infinity, minHeight: 30)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close player")
    }
}

private struct Artwork: View {
    let item: LibraryItem
    let isPlaying: Bool
    var maxSide: CGFloat = 420

    var body: some View {
        CoverView(source: item.coverSource, title: item.title, cornerRadius: 14)
            .shadow(color: .black.opacity(0.35), radius: isPlaying ? 28 : 14, y: isPlaying ? 16 : 8)
            .scaleEffect(isPlaying ? 1 : 0.86)
            .animation(.spring(response: 0.45, dampingFraction: 0.72), value: isPlaying)
            .padding(.vertical, 18)
            .frame(maxWidth: maxSide)
    }
}

private struct TitleBlock: View {
    /// Book (or podcast) title, shown small above.
    let context: String
    /// Chapter, or the episode/book title when there are no chapters.
    let title: String
    let chapterId: Int?

    var body: some View {
        VStack(spacing: 6) {
            Text(context)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .contentTransition(.opacity)
                .animation(.easeOut, value: chapterId)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Shown after finishing a book when the next one in its series is known.
private struct UpNextCard: View {
    let next: LibraryItem
    @Environment(AppModel.self) private var model

    var body: some View {
        let seriesName = model.library.series(containing: next.id)?.name
        HStack(spacing: 12) {
            CoverView(source: next.coverSource, title: next.title, cornerRadius: 6)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(seriesName.map { "Up next in \($0)" } ?? "Up next")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Text(next.title)
                    .font(.headline)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.player.open(next)
            } label: {
                Image(systemName: "play.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Play \(next.title)")
            Button {
                model.player.dismissSuggestion()
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.6))
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

/// Chapter-relative scrubber (whole-book if there are no chapters). This is the only player
/// view that reads the playhead, so only it re-renders while playing.
private struct Scrubber: View {
    @Environment(AppModel.self) private var model
    @State private var dragTime: Double?
    @GestureState private var isDragging = false

    var body: some View {
        let player = model.player
        let range = player.currentChapter.map { $0.start...$0.end } ?? 0...max(player.duration, 1)
        let length = max(range.upperBound - range.lowerBound, 0.001)
        let time = dragTime ?? player.time
        let fraction = ((time - range.lowerBound) / length).clamped(to: 0...1)
        let remainingBook = max(0, player.duration - time) / max(player.speed, 0.1)

        VStack(spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white.opacity(isDragging ? 1 : 0.9))
                        .frame(width: proxy.size.width * fraction)
                }
                .frame(height: isDragging ? 12 : 6)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($isDragging) { _, state, _ in state = true }
                        .onChanged { value in
                            let f = (value.location.x / proxy.size.width).clamped(to: 0...1)
                            dragTime = range.lowerBound + f * length
                        }
                        .onEnded { _ in
                            guard let target = dragTime else { return }
                            Task {
                                await player.seek(to: target)
                                dragTime = nil
                            }
                        }
                )
                .animation(.spring(response: 0.3), value: isDragging)
            }
            .frame(height: 20)
            .accessibilityElement()
            .accessibilityLabel("Chapter position")
            .accessibilityValue("\(Format.clock(time - range.lowerBound)) of \(Format.clock(length))")
            .accessibilityAdjustableAction { direction in
                player.skip(by: direction == .increment ? model.settings.skipForward : -model.settings.skipBackward)
            }

            HStack {
                Text(Format.clock(time - range.lowerBound))
                Spacer()
                if let index = player.currentChapterIndex, player.chapters.count > 1 {
                    Text("\(Format.timeLeft(remainingBook)) · \(index + 1) of \(player.chapters.count)")
                        .foregroundStyle(.white.opacity(0.55))
                } else {
                    Text(Format.timeLeft(remainingBook))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Text(Format.clock(-(range.upperBound - time)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.75))
        }
    }
}

private struct Transport: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        let settings = model.settings
        HStack {
            TransportButton(symbol: "backward.fill", size: 22, label: "Previous chapter") { player.previousChapter() }
                .disabled(player.chapters.isEmpty)
            Spacer()
            TransportButton(symbol: SkipSymbol.backward(settings.skipBackward), size: 30, label: "Back \(Int(settings.skipBackward)) seconds") {
                player.skip(by: -settings.skipBackward)
            }
            Spacer()
            Button {
                player.togglePlayPause()
            } label: {
                ZStack {
                    if player.isBuffering && !player.isPlaying {
                        ProgressView().controlSize(.large).tint(.white)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 46))
                            .contentTransition(.symbolEffect(.replace.downUp))
                    }
                }
                .frame(width: 72, height: 72)
                .contentShape(.circle)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Spacer()
            TransportButton(symbol: SkipSymbol.forward(settings.skipForward), size: 30, label: "Forward \(Int(settings.skipForward)) seconds") {
                player.skip(by: settings.skipForward)
            }
            Spacer()
            TransportButton(symbol: "forward.fill", size: 22, label: "Next chapter") { player.nextChapter() }
                .disabled(player.chapters.isEmpty)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: player.isPlaying)
    }
}

private struct TransportButton: View {
    let symbol: String
    let size: CGFloat
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: 52, height: 52)
                .contentShape(.circle)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

private struct VolumeRow: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill").font(.caption)
            SystemVolumeSlider().frame(height: 34)
            Image(systemName: "speaker.wave.3.fill").font(.caption)
        }
        .foregroundStyle(.white.opacity(0.7))
    }
}

/// The system volume slider (the only way to control device volume from an app).
private struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.tintColor = .white
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

private struct BottomBar: View {
    @Binding var showChapters: Bool
    @Binding var bookmarkAdded: Bool
    /// Off when the chapter list is always on screen (iPad landscape).
    var showsListToggle = true
    @Environment(AppModel.self) private var model
    @State private var bookmarkTrigger = 0

    var body: some View {
        let player = model.player
        HStack {
            Menu {
                Picker("Speed", selection: Binding(get: { player.speed }, set: { player.setSpeed($0) })) {
                    ForEach(Settings.speedPresets, id: \.self) { speed in
                        Text(Format.speed(speed)).tag(speed)
                    }
                }
            } label: {
                Text(Format.speed(player.speed))
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .frame(width: 56, height: 44)
            }
            .accessibilityLabel("Playback speed \(Format.speed(player.speed))")

            Spacer()
            RoutePicker().frame(width: 44, height: 44)
            Spacer()
            SleepMenu()
            Spacer()

            Button {
                bookmarkTrigger += 1
                withAnimation(.smooth) { bookmarkAdded = true }
                Task { await model.addBookmark() }
            } label: {
                Image(systemName: "bookmark")
                    .font(.title3.weight(.medium))
                    .frame(width: 44, height: 44)
            }
            .disabled(player.episode != nil)
            .sensoryFeedback(.success, trigger: bookmarkTrigger)
            .accessibilityLabel("Add bookmark")

            if showsListToggle {
                Spacer()
                Button {
                    showChapters.toggle()
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(showChapters ? Color.accentColor : .white)
                        .frame(width: 56, height: 44)
                }
                .disabled(player.chapters.isEmpty && player.episode != nil && player.queue.isEmpty)
                .accessibilityLabel(showChapters ? "Hide chapters and bookmarks" : "Show chapters and bookmarks")
            }
        }
        .foregroundStyle(.white.opacity(0.9))
    }
}

private struct SleepMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        Menu {
            if player.sleepTimer != .off {
                Button("Turn Off Timer", systemImage: "xmark") { player.cancelSleepTimer() }
            }
            Button("End of Chapter", systemImage: "book.pages") { player.setSleepAtEndOfChapter() }
                .disabled(player.chapters.isEmpty)
            ForEach([5.0, 10, 15, 30, 45, 60, 90], id: \.self) { minutes in
                Button("\(Int(minutes)) minutes") { player.setSleepTimer(minutes: minutes) }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: player.sleepTimer == .off ? "moon.zzz" : "moon.zzz.fill")
                    .font(.title3.weight(.medium))
                SleepRemaining(state: player.sleepTimer)
            }
            .foregroundStyle(player.sleepTimer == .off ? .white : Color.accentColor)
            .frame(minWidth: 56, minHeight: 44)
        }
        .accessibilityLabel("Sleep timer")
    }
}

/// Ticks once a second only while a countdown is running and visible.
private struct SleepRemaining: View {
    let state: SleepTimerState

    var body: some View {
        switch state {
        case .off:
            EmptyView()
        case .endOfChapter:
            Text("Ch.").font(.caption.weight(.semibold))
        case let .countdown(remaining, endsAt):
            if let endsAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Format.clock(max(0, endsAt.timeIntervalSince(context.date))))
                        .font(.caption.weight(.semibold).monospacedDigit())
                }
            } else {
                Text(Format.clock(remaining)).font(.caption.weight(.semibold).monospacedDigit())
            }
        }
    }
}

private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor.white.withAlphaComponent(0.9)
        view.activeTintColor = UIColor(named: "AccentColor")
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// Chapters, bookmarks and the up-next queue, shown in place of the artwork.
private struct ListPanel: View {
    enum Mode: String, CaseIterable { case chapters = "Chapters", bookmarks = "Bookmarks", queue = "Up Next" }

    let item: LibraryItem
    /// The header repeats the cover and chapter; it's left out beside the full-size artwork.
    var showsHeader = true
    let close: () -> Void
    @Environment(AppModel.self) private var model
    @State private var mode: Mode = .chapters

    var body: some View {
        let player = model.player
        let modes = Mode.allCases.filter { mode in
            switch mode {
            case .chapters: !player.chapters.isEmpty
            case .bookmarks: player.episode == nil
            case .queue: !player.queue.isEmpty
            }
        }
        VStack(spacing: 14) {
            if showsHeader {
                HStack(spacing: 12) {
                    CoverView(source: item.coverSource, title: item.title, cornerRadius: 6)
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.currentChapter?.title ?? player.displayTitle)
                            .font(.headline)
                            .lineLimit(1)
                        Text(item.title)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(.rect)
                .onTapGesture(perform: close)
            }

            if modes.count > 1 {
                Picker("Show", selection: $mode) {
                    ForEach(modes, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            switch modes.contains(mode) ? mode : (modes.first ?? .chapters) {
            case .chapters: ChapterList()
            case .bookmarks: PlayerBookmarkList(item: item)
            case .queue: QueueList()
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 16)
        .frame(maxHeight: .infinity)
    }
}

private struct ChapterList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(player.chapters.enumerated()), id: \.element.id) { index, chapter in
                        Button {
                            player.playChapter(chapter)
                        } label: {
                            ChapterRow(
                                chapter: chapter, number: index + 1,
                                state: ChapterRow.state(index: index, current: player.currentChapterIndex),
                                isPlaying: player.isPlaying, onDark: true
                            )
                        }
                        .buttonStyle(.plain)
                        .id(chapter.id)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                                         .init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .onAppear {
                if let current = player.currentChapter { proxy.scrollTo(current.id, anchor: .center) }
            }
        }
    }
}

private struct QueueList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let name = player.queueName {
                    Text("From \(name)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.bottom, 6)
                }
                ForEach(player.queue) { entry in
                    HStack(spacing: 12) {
                        CoverView(source: entry.item.coverSource, title: entry.item.title, cornerRadius: 5)
                            .frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.title).lineLimit(1)
                            if entry.episode != nil {
                                Text(entry.item.title).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                            } else if let author = entry.item.authorName {
                                Text(author).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            withAnimation { player.removeFromQueue(entry) }
                        } label: {
                            Image(systemName: "minus.circle").font(.title3)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.6))
                        .accessibilityLabel("Remove from Up Next")
                    }
                    .padding(.vertical, 8)
                }
                Button("Clear Up Next", role: .destructive) { withAnimation { player.clearQueue() } }
                    .font(.footnote.weight(.semibold))
                    .padding(.top, 10)
            }
        }
        .scrollIndicators(.hidden)
    }
}
