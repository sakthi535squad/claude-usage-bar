import Foundation

/// Where the current usage window is heading at the recent pace.
enum PaceForecast: Equatable {
    /// Not enough history in this window yet to call it.
    case measuring
    /// Projected to reach 100% at `at`, before the window resets.
    case full(at: Date)
    /// Projected to end the window at about this utilisation.
    case onPace(atReset: Double)
}

/// Fits a line through recent live readings of one usage window and projects
/// it to the reset. The readings arrive every ~5 minutes in whole-percent steps,
/// so anything shorter than `minSpan` is too coarse to extrapolate.
final class PaceTracker {
    let lookback: TimeInterval
    let minSpan: TimeInterval
    private var samples: [(at: Date, pct: Double)] = []
    private var resetsAt: Date?

    init(lookback: TimeInterval = 60 * 60, minSpan: TimeInterval = 15 * 60) {
        self.lookback = lookback
        self.minSpan = minSpan
    }

    func record(pct: Double, resetsAt: Date, at: Date) {
        // The API's reset time jitters by a second or so between polls; a real
        // new window moves it by hours.
        if let current = self.resetsAt, abs(current.timeIntervalSince(resetsAt)) > 60 {
            samples.removeAll()
        }
        self.resetsAt = resetsAt
        samples.append((at, pct))
        samples.removeAll { at.timeIntervalSince($0.at) > lookback }
    }

    func forecast(now: Date = Date()) -> PaceForecast {
        guard let reset = resetsAt, reset > now,
              let first = samples.first, let last = samples.last,
              samples.count >= 3, last.at.timeIntervalSince(first.at) >= minSpan
        else { return .measuring }

        // Least-squares slope, in percentage points per second.
        let t0 = first.at
        let xs = samples.map { $0.at.timeIntervalSince(t0) }
        let ys = samples.map(\.pct)
        let n = Double(samples.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let sxx = zip(xs, xs).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - mx) }
        let sxy = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        let slope = sxx > 0 ? max(0, sxy / sxx) : 0

        let current = last.pct
        let atReset = current + slope * reset.timeIntervalSince(now)
        if atReset >= 100, slope > 0 {
            return .full(at: now.addingTimeInterval(max(0, 100 - current) / slope))
        }
        return .onPace(atReset: atReset)
    }
}
