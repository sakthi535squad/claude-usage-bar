import Foundation

/// Pure text formatting shared by the themes. No AppKit, so it unit-tests alone.

/// Spend can pass its cap while the API still reports utilisation as 100,
/// so the real share comes from the amounts.
func spendShare(used: Double, limit: Double, reported: Double) -> Double {
    limit > 0 ? used / limit * 100 : reported
}

func money(_ amount: Double, _ currency: String) -> String {
    let sym = currency == "USD" ? "$" : ""
    let tail = currency == "USD" ? "" : " \(currency)"
    return amount.rounded() == amount
        ? "\(sym)\(Int(amount))\(tail)"
        : String(format: "%@%.2f%@", sym, amount, tail)
}

/// Bar with eighth-cell resolution: a 16-cell bar has 128 steps, so 1% moves
/// are visible instead of vanishing until they cross a whole cell.
func fineBar(_ pct: Double, width: Int) -> (filled: String, track: String) {
    let eighths = max(0, min(width * 8, Int((pct / 100 * Double(width * 8)).rounded())))
    let full = eighths / 8, part = eighths % 8
    let partials = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]
    let filled = String(repeating: "█", count: full) + partials[part]
    let used = full + (part > 0 ? 1 : 0)
    return (filled, String(repeating: "░", count: width - used))
}

/// One-cell vertical gauge for the menu bar: "▁" at 0% up to "█" at 100%.
func gauge(_ pct: Double) -> String {
    let levels = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
    let i = max(0, min(levels.count - 1, Int(pct / 100 * Double(levels.count))))
    return levels[i]
}
