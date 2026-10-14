import SwiftUI
import WidgetKit

// Streak and Past Year widgets. The app writes daily listening when stats load; the widgets add
// entries at midnight so the day rolls over without waking the app.

nonisolated struct ListeningEntry: TimelineEntry {
    let date: Date
    let days: [String: Double]?

    static var preview: ListeningEntry {
        // A plausible few months of listening for the gallery.
        var days: [String: Double] = [:]
        for offset in 0..<200 where offset % 7 != 3 && offset % 11 != 5 {
            let date = Calendar.current.date(byAdding: .day, value: -offset, to: .now)!
            days[ListeningDays.key(date)] = Double((offset * 37) % 90 + 5) * 60
        }
        return ListeningEntry(date: .now, days: days)
    }
}

nonisolated struct ListeningProvider: TimelineProvider {
    func placeholder(in context: Context) -> ListeningEntry { .preview }

    func getSnapshot(in context: Context, completion: @escaping (ListeningEntry) -> Void) {
        let days = WidgetData.listening()?.days
        completion(context.isPreview && days == nil ? .preview : ListeningEntry(date: .now, days: days))
    }

    /// Now, plus the next two midnights (when the streak and the grid move on a day).
    func getTimeline(in context: Context, completion: @escaping (Timeline<ListeningEntry>) -> Void) {
        let days = WidgetData.listening()?.days
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: .now)
        let dates = [Date.now] + (1...2).compactMap { calendar.date(byAdding: .day, value: $0, to: midnight) }
        completion(Timeline(entries: dates.map { ListeningEntry(date: $0, days: days) }, policy: .atEnd))
    }
}

// MARK: - Streak

struct StreakWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKinds.streak, provider: ListeningProvider()) { entry in
            StreakView(entry: entry)
        }
        .configurationDisplayName("Listening Streak")
        .description("How many days in a row you've listened.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct StreakView: View {
    let entry: ListeningEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .containerBackground(for: .widget) {
                if family.isAccessory {
                    AccessoryWidgetBackground().opacity(family == .accessoryCircular ? 1 : 0)
                } else {
                    Color("WidgetBackground")
                }
            }
    }

    @ViewBuilder private var content: some View {
        if let days = entry.days {
            let streak = ListeningDays.streak(days, now: entry.date)
            let today = ListeningDays.listenedToday(days, now: entry.date)
            switch family {
            case .accessoryCircular:
                VStack(spacing: 0) {
                    Image(systemName: "flame.fill").font(.caption).widgetAccentable()
                    Text("\(streak)").font(.title2.weight(.bold)).minimumScaleFactor(0.6)
                }
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    Label(streak == 1 ? "1-day streak" : "\(streak)-day streak", systemImage: "flame.fill")
                        .font(.headline)
                        .widgetAccentable()
                    Text(today ? "Listened today" : "Not yet today").font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .accessoryInline:
                Label(streak == 1 ? "1-day listening streak" : "\(streak)-day listening streak", systemImage: "flame.fill")
            default:
                SmallStreak(days: days, streak: streak, listenedToday: today, date: entry.date)
            }
        } else {
            NoListeningData(family: family)
        }
    }
}

private struct SmallStreak: View {
    let days: [String: Double]
    let streak: Int
    let listenedToday: Bool
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Streak", systemImage: "flame.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.shelfAccent)
                .widgetAccentable()
            Spacer(minLength: 0)
            Text("\(streak)")
                .font(.system(size: 46, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(streak == 1 ? "day in a row" : "days in a row")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            WeekDots(days: days, date: date)
            Text(listenedToday ? "Listened today" : "Listen today to keep it going")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The last seven days, filled where you listened.
private struct WeekDots: View {
    let days: [String: Double]
    let date: Date

    var body: some View {
        let keys = ListeningDays.lastDays(7, from: date)
        HStack(spacing: 5) {
            ForEach(keys, id: \.self) { key in
                let listened = (days[key] ?? 0) >= ListeningDays.minimumSeconds
                Circle()
                    .fill(listened ? Color.shelfAccent : Color.primary.opacity(0.12))
                    .frame(width: 11, height: 11)
                    .widgetAccentable(listened)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Past Year

struct ActivityWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKinds.activity, provider: ListeningProvider()) { entry in
            ActivityView(entry: entry)
        }
        .configurationDisplayName("Past Year")
        .description("Your listening over the last year, a square for each day.")
        .supportedFamilies([.systemMedium])
    }
}

private struct ActivityView: View {
    let entry: ListeningEntry

    var body: some View {
        Group {
            if let days = entry.days {
                let year = ListeningDays.lastDays(371, from: entry.date)
                let listened = year.filter { (days[$0] ?? 0) >= ListeningDays.minimumSeconds }.count
                let total = year.reduce(0) { $0 + (days[$1] ?? 0) }
                let streak = ListeningDays.streak(days, now: entry.date)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Past Year").font(.headline)
                        Spacer()
                        Text(listened == 1 ? "1 day listened" : "\(listened) days listened")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    ActivityGrid(days: days, date: entry.date)
                    Spacer(minLength: 6)
                    HStack {
                        Label(streak == 1 ? "1-day streak" : "\(streak)-day streak", systemImage: "flame.fill")
                            .foregroundStyle(Color.shelfAccent)
                            .widgetAccentable()
                        Spacer()
                        Text("\(Format.duration(total)) listened")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption2.weight(.medium).monospacedDigit())
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Listening over the past year: \(listened) days, \(Format.duration(total)). \(streak)-day streak.")
            } else {
                NoListeningData(family: .systemMedium)
            }
        }
        .containerBackground(for: .widget) { Color("WidgetBackground") }
    }
}

/// The in-app activity graph in miniature: a full year of week columns sized to the widget's
/// width, drawn as one path per intensity level (five shapes rather than hundreds of views).
private struct ActivityGrid: View {
    let days: [String: Double]
    let date: Date

    private static let weeks = 53
    /// Gap between squares as a fraction of a square.
    private static let gapRatio: CGFloat = 0.3
    private static let labelHeight: CGFloat = 11

    var body: some View {
        let columns = ListeningDays.weeks(Self.weeks, days: days, now: date)
        let thresholds = ListeningDays.thresholds(days.values)
        let units = CGFloat(Self.weeks) + CGFloat(Self.weeks - 1) * Self.gapRatio
        GeometryReader { proxy in
            let cell = proxy.size.width / units
            let gap = cell * Self.gapRatio
            VStack(alignment: .leading, spacing: 3) {
                ZStack(alignment: .topLeading) {
                    ForEach(0..<5, id: \.self) { level in
                        cells(columns, level: level, thresholds: thresholds, cell: cell, gap: gap)
                            .fill(level == 0 ? Color.primary.opacity(0.1) : Color.shelfAccent.opacity(ListeningDays.opacity(forLevel: level)))
                            .widgetAccentable(level > 0)
                    }
                }
                .frame(height: cell * 7 + gap * 6)
                monthLabels(columns, step: cell + gap)
            }
        }
        // Height follows from the width: seven squares and six gaps, plus the month labels.
        .aspectRatio(units / (7 + 6 * Self.gapRatio), contentMode: .fit)
        .padding(.bottom, Self.labelHeight + 3)
    }

    private func cells(_ columns: [[(date: Date, seconds: Double)]], level: Int, thresholds: [Double], cell: CGFloat, gap: CGFloat) -> Path {
        var path = Path()
        for (x, week) in columns.enumerated() {
            for (y, day) in week.enumerated() where ListeningDays.level(day.seconds, thresholds) == level {
                let rect = CGRect(x: CGFloat(x) * (cell + gap), y: CGFloat(y) * (cell + gap), width: cell, height: cell)
                path.addRoundedRect(in: rect, cornerSize: CGSize(width: cell * 0.25, height: cell * 0.25), style: .continuous)
            }
        }
        return path
    }

    /// Month initials under the first week containing the 1st, skipping any too close to the edge.
    private func monthLabels(_ columns: [[(date: Date, seconds: Double)]], step: CGFloat) -> some View {
        let calendar = Calendar.current
        let starts = columns.enumerated().compactMap { index, week -> (Int, Date)? in
            week.first { calendar.component(.day, from: $0.date) == 1 }.map { (index, $0.date) }
        }
        return ZStack(alignment: .topLeading) {
            ForEach(starts.filter { $0.0 < columns.count - 2 }, id: \.0) { index, date in
                Text(date.formatted(.dateTime.month(.abbreviated)))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .offset(x: CGFloat(index) * step)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.labelHeight, alignment: .topLeading)
    }
}

private struct NoListeningData: View {
    let family: WidgetFamily

    var body: some View {
        switch family {
        case .accessoryInline:
            Label("Open Shelf to load your listening", systemImage: "flame")
        case .accessoryCircular:
            Image(systemName: "flame").font(.title2)
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text("Listening").font(.headline).widgetAccentable()
                Text("Open Shelf to load").font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(spacing: 6) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.title2)
                    .foregroundStyle(Color.shelfAccent)
                Text("Open Shelf to load your listening.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
