import Charts
import SwiftUI

/// Listening stats from the server: totals, the last week, streaks, top books, this year in
/// review and recent sessions across all your devices.
struct StatsView: View {
    @Environment(AppModel.self) private var model
    @State private var stats: ListeningStats?
    @State private var year: YearStats?
    @State private var error: String?

    var body: some View {
        ScrollView {
            if let stats {
                VStack(spacing: 18) {
                    if model.localSessions.hasPending {
                        Label("Some offline listening hasn't been uploaded yet.", systemImage: "icloud.and.arrow.up")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    summary(stats)
                    ActivityGraph(days: stats.days)
                    WeekChart(days: stats.days)
                    if let year { YearCard(year: year) }
                    topItems(stats)
                    recentSessions(stats)
                }
                .padding()
                .readableWidth(760)
            }
        }
        .navigationTitle("Listening")
        .overlay {
            if stats == nil {
                if let error {
                    ContentUnavailableView("Couldn't Load Stats", systemImage: "chart.bar.xaxis", description: Text(error))
                } else {
                    ProgressView()
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let api = model.api else { return }
        if model.network.isOnline { await model.localSessions.upload(using: api) }
        async let statsTask = api.get("api/me/listening-stats", cached: true, as: ListeningStats.self)
        async let yearTask = api.get("api/me/stats/year/\(Calendar.current.component(.year, from: .now))", cached: true, as: YearStats.self)
        do {
            let loaded = try await statsTask
            stats = loaded
            error = nil
            model.broadcaster.widgets.updateListening(loaded.days)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        year = try? await yearTask
    }

    // MARK: - Sections

    private func summary(_ stats: ListeningStats) -> some View {
        let week = Self.lastDays(7).reduce(0) { $0 + (stats.days[$1] ?? 0) }
        return Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                Tile(value: Format.duration(stats.today ?? 0), label: "Today", icon: "sun.max")
                Tile(value: Format.duration(week), label: "Last 7 Days", icon: "calendar")
            }
            GridRow {
                Tile(value: streakText(stats.days), label: "Day Streak", icon: "flame")
                Tile(value: Format.duration(stats.totalTime), label: "All Time", icon: "hourglass")
            }
        }
    }

    private func streakText(_ days: [String: Double]) -> String {
        // Today counts if you've listened; otherwise the streak can still be alive from yesterday.
        var streak = 0
        var date = Date.now
        if (days[Self.key(date)] ?? 0) < 60 { date = Calendar.current.date(byAdding: .day, value: -1, to: date)! }
        while (days[Self.key(date)] ?? 0) >= 60 {
            streak += 1
            date = Calendar.current.date(byAdding: .day, value: -1, to: date)!
        }
        return streak == 1 ? "1 day" : "\(streak) days"
    }

    @ViewBuilder private func topItems(_ stats: ListeningStats) -> some View {
        let items = (stats.items ?? [:]).values.sorted { $0.timeListening > $1.timeListening }.prefix(5)
        if !items.isEmpty {
            Card(title: "Most Listened") {
                ForEach(Array(items), id: \.id) { entry in
                    let item = model.library.item(entry.id)
                    let row = HStack(spacing: 12) {
                        CoverView(source: LibraryItem.coverSource(id: entry.id, version: item?.coverVersion ?? 0),
                                  title: entry.mediaMetadata?.title ?? "", cornerRadius: 5)
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.mediaMetadata?.title ?? "Unknown").lineLimit(1)
                            if let author = entry.mediaMetadata?.authorName {
                                Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        Text(Format.duration(entry.timeListening))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                    if let item {
                        NavigationLink(value: item) { row }.buttonStyle(.plain)
                    } else {
                        row
                    }
                }
            }
        }
    }

    @ViewBuilder private func recentSessions(_ stats: ListeningStats) -> some View {
        let sessions = (stats.recentSessions ?? []).prefix(10)
        if !sessions.isEmpty {
            Card(title: "Recent Sessions") {
                ForEach(Array(sessions)) { session in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.displayTitle ?? "Unknown").lineLimit(1)
                            Text(sessionDetail(session))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(Format.duration(session.timeListening ?? 0))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func sessionDetail(_ session: ListeningSession) -> String {
        let device = session.deviceInfo.flatMap { $0.deviceName.nonEmpty ?? $0.clientName.nonEmpty ?? $0.model.nonEmpty }
        let when = session.updatedDate.map { $0.formatted(.relative(presentation: .named)) }
        return [when, device].compactMap { $0 }.joined(separator: " · ")
    }

    static func key(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func lastDays(_ count: Int) -> [String] {
        (0..<count).reversed().compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: .now).map(key) }
    }
}

extension LibraryItem {
    static func coverSource(id: String, version: Int) -> ImageSource { .cover(itemId: id, version: version) }
}

private struct Tile: View {
    let value: String
    let label: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))
    }
}

private struct WeekChart: View {
    let days: [String: Double]

    var body: some View {
        let keys = StatsView.lastDays(7)
        let points = keys.map { key in (key: key, minutes: (days[key] ?? 0) / 60) }
        Card(title: "This Week") {
            Chart(points, id: \.key) { point in
                BarMark(
                    x: .value("Day", Self.weekday(point.key)),
                    y: .value("Minutes", point.minutes)
                )
                .foregroundStyle(Color.accentColor.gradient)
                .cornerRadius(4)
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { if let minutes = value.as(Double.self) { Text(Format.duration(minutes * 60)) } }
                }
            }
            .frame(height: 160)
        }
    }

    private static func weekday(_ key: String) -> String {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return key }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }
}

private struct YearCard: View {
    let year: YearStats

    var body: some View {
        let current = Calendar.current.component(.year, from: .now)
        Card(title: "\(String(current)) So Far") {
            VStack(spacing: 10) {
                row("Listening time", Format.duration(year.totalListeningTime ?? 0))
                row("Books finished", "\(year.numBooksFinished ?? 0)")
                row("Books listened to", "\(year.numBooksListened ?? 0)")
                if let author = year.topAuthors?.first?.name { row("Top author", author) }
                if let genre = year.topGenres?.first?.genre { row("Top genre", genre) }
                if let narrator = year.mostListenedNarrator?.name { row("Top narrator", narrator) }
                if let month = year.mostListenedMonth?.month, (0..<12).contains(month) {
                    row("Biggest month", Calendar.current.monthSymbols[month])
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value).fontWeight(.medium).multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}
