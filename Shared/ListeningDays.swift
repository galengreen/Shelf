import Foundation

/// Listening history as the server reports it ("YYYY-MM-DD" → seconds), plus the maths the stats
/// screen and the widgets share: day keys, streaks and the activity grid's intensity levels.
nonisolated struct ListeningSnapshot: Codable, Hashable, Sendable {
    /// Only the last year or so, which is all the widgets draw.
    var days: [String: Double]
    var updatedAt: Date
}

nonisolated enum ListeningDays {
    /// A day counts towards the streak and the grid after a minute of listening.
    static let minimumSeconds: Double = 60

    static func key(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Keys for the last `count` days, oldest first, ending today.
    static func lastDays(_ count: Int, from now: Date = .now) -> [String] {
        (0..<count).reversed().compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: now).map { key($0) } }
    }

    /// Consecutive days listened. Today counts if you've listened; otherwise the streak is still
    /// alive from yesterday until the day is over.
    static func streak(_ days: [String: Double], now: Date = .now) -> Int {
        let calendar = Calendar.current
        var streak = 0
        var date = now
        if (days[key(date)] ?? 0) < minimumSeconds { date = calendar.date(byAdding: .day, value: -1, to: date)! }
        while (days[key(date)] ?? 0) >= minimumSeconds {
            streak += 1
            date = calendar.date(byAdding: .day, value: -1, to: date)!
        }
        return streak
    }

    static func listenedToday(_ days: [String: Double], now: Date = .now) -> Bool {
        (days[key(now)] ?? 0) >= minimumSeconds
    }

    /// Week columns of (date, seconds), oldest first, ending with the current week; days after
    /// today are left out.
    static func weeks(_ count: Int, days: [String: Double], now: Date = .now) -> [[(date: Date, seconds: Double)]] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start,
              let start = calendar.date(byAdding: .weekOfYear, value: -(count - 1), to: thisWeek) else { return [] }
        return (0..<count).map { week in
            (0..<7).compactMap { offset in
                guard let date = calendar.date(byAdding: .day, value: week * 7 + offset, to: start), date <= today else { return nil }
                return (date, days[key(date)] ?? 0)
            }
        }
    }

    /// Upper bounds for levels 1–3 (quartiles of the days you listened); anything above is level 4.
    static func thresholds(_ values: some Sequence<Double>) -> [Double] {
        let sorted = values.filter { $0 >= minimumSeconds }.sorted()
        guard !sorted.isEmpty else { return [900, 1800, 3600] }
        return [0.25, 0.5, 0.75].map { sorted[min(sorted.count - 1, Int(Double(sorted.count) * $0))] }
    }

    static func level(_ seconds: Double, _ thresholds: [Double]) -> Int {
        guard seconds >= minimumSeconds else { return 0 }
        return (thresholds.firstIndex { seconds <= $0 } ?? 3) + 1
    }

    /// Opacity of the accent for each level; level 0 is a neutral track.
    static func opacity(forLevel level: Int) -> Double {
        switch level {
        case 1: 0.38
        case 2: 0.58
        case 3: 0.8
        default: 1
        }
    }
}
