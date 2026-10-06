import Foundation

private let configDir = NSHomeDirectory() + "/.config/claude-usage-bar"

/// List prices in USD per million tokens. Cache writes are priced off input:
/// 1.25× for a 5-minute TTL, 2× for 1 hour. Cache reads are listed per model
/// because they are not a fixed share of input on every model.
struct Price: Equatable {
    let input: Double
    let output: Double
    let cacheRead: Double
}

/// Longest prefix wins, so `claude-opus-5-5` is not priced as `claude-opus-5`.
private let prices: [(prefix: String, price: Price)] = [
    ("claude-fable-5-1", Price(input: 10, output: 50, cacheRead: 0.25)),
    ("claude-mythos-5-1", Price(input: 10, output: 50, cacheRead: 0.25)),
    ("claude-fable-5", Price(input: 10, output: 50, cacheRead: 1.00)),
    ("claude-mythos-5", Price(input: 10, output: 50, cacheRead: 1.00)),
    ("claude-opus-5-5", Price(input: 4, output: 20, cacheRead: 0.20)),
    ("claude-opus-5", Price(input: 5, output: 25, cacheRead: 0.50)),
    ("claude-opus-4", Price(input: 5, output: 25, cacheRead: 0.50)),
    ("claude-sonnet-5", Price(input: 2, output: 10, cacheRead: 0.20)),
    ("claude-sonnet-4", Price(input: 3, output: 15, cacheRead: 0.30)),
    ("claude-haiku-4", Price(input: 1, output: 5, cacheRead: 0.10)),
]

func price(for model: String?) -> Price? {
    guard let model else { return nil }
    return prices.filter { model.hasPrefix($0.prefix) }.max { $0.prefix.count < $1.prefix.count }?.price
}

/// What one ping cost at list price, or nil for a model not in the table.
/// `total_cost_usd` from `claude -p` is no use here: on a resumed session it
/// includes everything the session had already spent.
func pingCost(_ r: PingResult, model: String?) -> Double? {
    guard let p = price(for: model) else { return nil }
    let perToken = 1.0 / 1_000_000
    let write5m = r.cacheWrite - r.cacheWrite1h
    return (Double(r.input) * p.input
            + Double(r.output) * p.output
            + Double(r.cacheRead) * p.cacheRead
            + Double(write5m) * p.input * 1.25
            + Double(r.cacheWrite1h) * p.input * 2) * perToken
}

/// Keep-warm totals for one local calendar day.
struct SpendDay: Codable, Equatable {
    let day: String
    var pings = 0
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var cost = 0.0
    /// Pings whose model had no price, so `cost` leaves them out.
    var unpriced = 0

    mutating func add(_ other: SpendDay) {
        pings += other.pings
        input += other.input
        output += other.output
        cacheRead += other.cacheRead
        cacheWrite += other.cacheWrite
        cost += other.cost
        unpriced += other.unpriced
    }
}

/// Per-day keep-warm token and cost totals, kept for `keepDays` in
/// `keepwarm-spend.json`. Only successful pings are recorded; a failed one
/// has no usage to count.
final class SpendLedger {
    static let keepDays = 30
    private let path: String
    private(set) var days: [String: SpendDay] = [:]

    init(path: String = configDir + "/keepwarm-spend.json") {
        self.path = path
        if let data = FileManager.default.contents(atPath: path),
           let list = try? JSONDecoder().decode([SpendDay].self, from: data) {
            days = Dictionary(list.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    func record(_ r: PingResult, model: String?, at: Date) {
        let key = Self.dayKey(at)
        var d = days[key] ?? SpendDay(day: key)
        d.pings += 1
        d.input += r.input
        d.output += r.output
        d.cacheRead += r.cacheRead
        d.cacheWrite += r.cacheWrite
        if let c = pingCost(r, model: model) { d.cost += c } else { d.unpriced += 1 }
        days[key] = d
        let oldest = Self.dayKey(max(at, Date()).addingTimeInterval(-Double(Self.keepDays) * 86400))
        days = days.filter { $0.key > oldest }
        save()
    }

    /// Totals for the `count` days ending on `now`'s day.
    func total(days count: Int, now: Date = Date()) -> SpendDay {
        let keys = Set((0..<count).map { Self.dayKey(now.addingTimeInterval(-Double($0) * 86400)) })
        var sum = SpendDay(day: "")
        for (k, d) in days where keys.contains(k) { sum.add(d) }
        return sum
    }

    private func save() {
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? e.encode(days.values.sorted { $0.day < $1.day }) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    static func dayKey(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

func formatCost(_ usd: Double) -> String {
    usd < 0.01 && usd > 0 ? "<$0.01" : String(format: "$%.2f", usd)
}

/// `12 pings · $0.31 · read 1.2M write 40k in 24 out 96`
func spendSummary(_ d: SpendDay) -> String {
    var s = "\(d.pings) ping\(d.pings == 1 ? "" : "s") · \(formatCost(d.cost))"
    if d.unpriced > 0 { s += "+" }
    return s + " · read \(formatTokens(d.cacheRead)) write \(formatTokens(d.cacheWrite))"
        + " in \(formatTokens(d.input)) out \(formatTokens(d.output))"
}
