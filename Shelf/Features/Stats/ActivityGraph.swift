import SwiftUI

/// GitHub-style calendar of the last year's listening: one square per day, columns are weeks.
/// Intensity is one hue (the accent) from faint to full, with steps set by your own listening
/// (quartiles of the days you listened), so a light week and a heavy week both read clearly.
struct ActivityGraph: View {
    /// "YYYY-MM-DD" → seconds listened.
    let days: [String: Double]

    @State private var selected: Day?

    private static let weeks = 53
    private static let cell: CGFloat = 12
    private static let gap: CGFloat = 3

    struct Day: Identifiable, Equatable {
        let date: Date
        let seconds: Double
        var id: Date { date }
    }

    var body: some View {
        let columns = Self.columns(days: days)
        let thresholds = Self.thresholds(days.values)
        let listened = columns.joined().filter { $0.seconds >= 60 }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Past Year").font(.headline)
                Spacer()
                Group {
                    if let selected {
                        Text("\(Format.duration(selected.seconds)) on \(selected.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))")
                    } else {
                        Text(listened.count == 1 ? "1 day listened" : "\(listened.count) days listened")
                    }
                }
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            }

            HStack(alignment: .top, spacing: 6) {
                weekdayLabels
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 4) {
                        monthLabels(columns)
                        HStack(spacing: Self.gap) {
                            ForEach(Array(columns.enumerated()), id: \.offset) { _, week in
                                VStack(spacing: Self.gap) {
                                    ForEach(week) { day in
                                        cell(day, level: Self.level(day.seconds, thresholds))
                                    }
                                }
                                .frame(maxHeight: .infinity, alignment: .top)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(.trailing)
            }

            legend
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Listening over the past year")
        .accessibilityValue(accessibilitySummary(listened))
    }

    // MARK: - Pieces

    private func cell(_ day: Day, level: Int) -> some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(Self.color(level))
            .frame(width: Self.cell, height: Self.cell)
            .overlay {
                if selected == day {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .strokeBorder(Color.primary, lineWidth: 1.5)
                }
            }
            // A larger hit target than the square itself.
            .padding(Self.gap / 2)
            .contentShape(.rect)
            .padding(-Self.gap / 2)
            .onTapGesture {
                withAnimation(.snappy(duration: 0.2)) { selected = selected == day ? nil : day }
            }
    }

    /// Monday, Wednesday and Friday, like GitHub, wherever they fall in the user's week.
    private var weekdayLabels: some View {
        let calendar = Calendar.current
        let symbols = calendar.veryShortWeekdaySymbols
        let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 }
        return VStack(alignment: .trailing, spacing: Self.gap) {
            // Spacer matching the month label row.
            Text(" ").font(.caption2).padding(.bottom, 4 - Self.gap)
            ForEach(0..<7, id: \.self) { row in
                // Calendar weekdays: 2 = Monday, 4 = Wednesday, 6 = Friday (index + 1).
                Text([1, 3, 5].contains(order[row]) ? symbols[order[row]] : " ")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(height: Self.cell)
            }
        }
    }

    private func monthLabels(_ columns: [[Day]]) -> some View {
        HStack(spacing: Self.gap) {
            ForEach(Array(columns.enumerated()), id: \.offset) { index, week in
                // Label the first week that contains the 1st of a month (and the very first week).
                let first = week.first { Calendar.current.component(.day, from: $0.date) == 1 }
                let label = first.map { $0.date.formatted(.dateTime.month(.abbreviated)) }
                Text(label ?? " ")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .frame(width: Self.cell, alignment: .leading)
                    .opacity(index == columns.count - 1 && label != nil ? 0 : 1) // avoid clipping at the end
            }
        }
    }

    private var legend: some View {
        HStack(spacing: Self.gap) {
            Spacer()
            Text("Less").padding(.trailing, 3)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(Self.color(level))
                    .frame(width: Self.cell, height: Self.cell)
            }
            Text("More").padding(.leading, 3)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func accessibilitySummary(_ listened: [Day]) -> String {
        let total = listened.reduce(0) { $0 + $1.seconds }
        guard let best = listened.max(by: { $0.seconds < $1.seconds }) else { return "No listening" }
        return "\(listened.count) days listened, \(Format.duration(total)) in total. Most was \(Format.duration(best.seconds)) on \(best.date.formatted(date: .long, time: .omitted))."
    }

    // MARK: - Data

    /// Columns of seven days ending with the current week; days after today are left out.
    private static func columns(days: [String: Double]) -> [[Day]] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start,
              let start = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek) else { return [] }
        return (0..<weeks).map { week in
            (0..<7).compactMap { offset -> Day? in
                guard let date = calendar.date(byAdding: .day, value: week * 7 + offset, to: start), date <= today else { return nil }
                return Day(date: date, seconds: days[StatsView.key(date)] ?? 0)
            }
        }
    }

    /// Upper bounds for levels 1–3; anything above is level 4.
    private static func thresholds(_ values: some Sequence<Double>) -> [Double] {
        let sorted = values.filter { $0 >= 60 }.sorted()
        guard !sorted.isEmpty else { return [900, 1800, 3600] }
        return [0.25, 0.5, 0.75].map { sorted[min(sorted.count - 1, Int(Double(sorted.count) * $0))] }
    }

    private static func level(_ seconds: Double, _ thresholds: [Double]) -> Int {
        guard seconds >= 60 else { return 0 }
        return (thresholds.firstIndex { seconds <= $0 } ?? 3) + 1
    }

    /// Level 0 is a neutral track; 1–4 step the accent from faint to full, so lightness changes
    /// monotonically in both light mode (pale → strong) and dark mode (dim → bright).
    private static func color(_ level: Int) -> Color {
        switch level {
        case 0: Color.primary.opacity(0.08)
        case 1: Color.accentColor.opacity(0.38)
        case 2: Color.accentColor.opacity(0.58)
        case 3: Color.accentColor.opacity(0.8)
        default: Color.accentColor
        }
    }
}
