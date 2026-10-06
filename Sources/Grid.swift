import Cocoa

/// A character grid, as a terminal holds its screen. Themes compose into this
/// and `GridPanelView` paints it, so a panel's columns line up regardless of
/// which font a glyph falls back to.
struct Grid {
    struct Cell {
        var ch: Character = " "
        var fg: NSColor = .labelColor
        var bg: NSColor?
        var bold = false
        /// A bar track painted under a partial block, so the cell is not half empty.
        var under: NSColor?
    }

    let cols: Int
    private(set) var rows: [[Cell]]

    init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = Array(repeating: Array(repeating: Cell(), count: cols), count: rows)
    }

    /// Writes `s` from `col`, clipping at the right edge. Returns the column after it.
    @discardableResult
    mutating func put(_ s: String, row: Int, col: Int, fg: NSColor = .labelColor,
                      bg: NSColor? = nil, bold: Bool = false) -> Int {
        guard rows.indices.contains(row) else { return col }
        var c = col
        for ch in s {
            if c >= cols { break }
            if c >= 0 { rows[row][c] = Cell(ch: ch, fg: fg, bg: bg, bold: bold) }
            c += 1
        }
        return c
    }

    /// Right-aligns `s` so it ends just before column `end`.
    @discardableResult
    mutating func putRight(_ s: String, row: Int, end: Int, fg: NSColor = .labelColor,
                           bg: NSColor? = nil, bold: Bool = false) -> Int {
        put(s, row: row, col: end - s.count, fg: fg, bg: bg, bold: bold)
    }

    mutating func setUnder(row: Int, col: Int, _ color: NSColor) {
        guard rows.indices.contains(row), (0..<cols).contains(col) else { return }
        rows[row][col].under = color
    }

    mutating func fill(row: Int, from: Int, to: Int, bg: NSColor) {
        guard rows.indices.contains(row) else { return }
        for c in max(0, from)..<min(cols, to) { rows[row][c].bg = bg }
    }

    /// A rounded box over rows `top...bottom`, spanning every column.
    mutating func box(top: Int, bottom: Int, color: NSColor) {
        put("╭" + String(repeating: "─", count: max(0, cols - 2)) + "╮", row: top, col: 0, fg: color)
        put("╰" + String(repeating: "─", count: max(0, cols - 2)) + "╯", row: bottom, col: 0, fg: color)
        for r in (top + 1)..<bottom {
            put("│", row: r, col: 0, fg: color)
            put("│", row: r, col: cols - 1, fg: color)
        }
    }

    /// A rich-style bar: heavy line filled in `fg`, the rest of the track dimmed,
    /// with a half cell at the boundary for twice the resolution.
    mutating func heavyBar(_ pct: Double, row: Int, col: Int, width: Int, fg: NSColor, track: NSColor) {
        let halves = max(0, min(width * 2, Int((pct / 100 * Double(width * 2)).rounded())))
        let full = halves / 2
        put(String(repeating: "━", count: full), row: row, col: col, fg: fg)
        var c = col + full
        if halves % 2 == 1, c < cols {
            // Two colours in one cell, which a Cell cannot hold: left half fill,
            // right half track. The view paints it from `splitCells`.
            put(" ", row: row, col: c)
            splitCells.append((row, c, fg, track))
            c += 1
        }
        put(String(repeating: "━", count: max(0, col + width - c)), row: row, col: c, fg: track)
    }

    /// Cells drawn as a half-fill, half-track heavy line. Kept aside because a
    /// cell otherwise carries one foreground colour.
    private(set) var splitCells: [(row: Int, col: Int, left: NSColor, right: NSColor)] = []
}

extension Grid {
    /// Writes (text, colour) runs from `col`; returns the column after them.
    @discardableResult
    mutating func put(_ parts: [(String, NSColor)], row: Int, col: Int, bold: Bool = false) -> Int {
        var c = col
        for (s, color) in parts { c = put(s, row: row, col: c, fg: color, bold: bold) }
        return c
    }

    /// An eighth-cell block bar with a dim full-width track behind it.
    mutating func blockBar(_ pct: Double, row: Int, col: Int, width: Int, fg: NSColor, track: NSColor) {
        put(String(repeating: "░", count: width), row: row, col: col, fg: track)
        let (filled, _) = fineBar(pct, width: width)
        let end = put(filled, row: row, col: col, fg: fg)
        if filled.last != "█", end > col { setUnder(row: row, col: end - 1, track) }
    }
}
