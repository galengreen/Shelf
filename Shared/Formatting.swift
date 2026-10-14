import Foundation

nonisolated enum Format {
    /// 1:02:03 or 12:34. Negative values get a leading minus (for "time remaining").
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let negative = seconds < 0
        let total = Int(abs(seconds).rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        let body = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        return negative ? "-" + body : body
    }

    /// "11h 14m", "42m", "<1m".
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0m" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        if m > 0 { return "\(m)m" }
        return "<1m"
    }

    static func timeLeft(_ seconds: Double) -> String {
        "\(duration(seconds)) left"
    }

    static func speed(_ value: Double) -> String {
        let text = value.formatted(.number.precision(.fractionLength(0...2)))
        return "\(text)×"
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func skip(_ seconds: Double) -> String {
        String(Int(seconds))
    }
}

extension Double {
    nonisolated func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// SF Symbols for skip buttons: numbered where a symbol exists for the interval.
nonisolated enum SkipSymbol {
    private static let available: Set<Int> = [5, 10, 15, 30, 45, 60, 75, 90]

    static func forward(_ seconds: Double) -> String {
        available.contains(Int(seconds)) ? "goforward.\(Int(seconds))" : "goforward"
    }

    static func backward(_ seconds: Double) -> String {
        available.contains(Int(seconds)) ? "gobackward.\(Int(seconds))" : "gobackward"
    }
}
