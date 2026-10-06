import Cocoa

// Formatting and grid layout behind the themes. Pure: no menu, no AppKit views.
var failed = false
func check<T: Equatable>(_ label: String, _ got: T, _ want: T) {
    if got != want { failed = true }
    print("\(got == want ? "PASS" : "FAIL")  \(label): got \(got), want \(want)")
}
func text(_ g: Grid, _ row: Int) -> String { String(g.rows[row].map(\.ch)) }

// fineBar: 18 cells is 144 eighths, so 72% is 103.68 → 104 eighths = 13 full cells.
let b72 = fineBar(72, width: 18)
check("72% of 18 cells fills 13", b72.filled, String(repeating: "█", count: 13))
check("72% of 18 cells leaves 5 track", b72.track.count, 5)
// 1% of 144 eighths is 1.44 → 1 eighth: visible, where whole cells would show nothing.
check("1% still shows an eighth", fineBar(1, width: 18).filled, "▏")
check("1% track fills the rest", fineBar(1, width: 18).track.count, 17)
check("0% is all track", fineBar(0, width: 4).filled + fineBar(0, width: 4).track, "░░░░")
check("over 100% clamps to full", fineBar(150, width: 4).filled, "████")
check("over 100% has no track", fineBar(150, width: 4).track, "")
check("width never exceeded", fineBar(99.9, width: 7).filled.count + fineBar(99.9, width: 7).track.count, 7)

check("gauge floor", gauge(0), "▁")
check("gauge 72% is level 6 of 8", gauge(72), "▆")
check("gauge ceiling", gauge(100), "█")

check("whole dollars", money(225, "USD"), "$225")
check("cents kept", money(12.5, "USD"), "$12.50")
check("other currency", money(10, "EUR"), "10 EUR")

// The API reports 100 once the cap is hit; the amounts say how far past it.
check("spend past cap", spendShare(used: 225, limit: 200, reported: 100), 112.5)
check("no limit falls back to reported", spendShare(used: 5, limit: 0, reported: 40), 40)

var g = Grid(cols: 10, rows: 3)
check("put returns next column", g.put("abc", row: 0, col: 2), 5)
check("put writes in place", text(g, 0), "  abc     ")
g.put("0123456789XYZ", row: 1, col: 0)
check("put clips at the right edge", text(g, 1), "0123456789")
g.putRight("42%", row: 2, end: 10)
check("putRight ends at end", text(g, 2), "       42%")

var bar = Grid(cols: 4, rows: 1)
bar.heavyBar(50, row: 0, col: 0, width: 4, fg: .red, track: .gray)
check("half bar: four heavy cells", text(bar, 0), "━━━━")
check("half bar: first two are fill", bar.rows[0].prefix(2).allSatisfy { $0.fg == .red }, true)
check("half bar: last two are track", bar.rows[0].suffix(2).allSatisfy { $0.fg == .gray }, true)
check("half bar: no split cell", bar.splitCells.count, 0)

// 62.5% of 8 half-cells is 5: two full cells, then one cell half fill, half track.
var split = Grid(cols: 4, rows: 1)
split.heavyBar(62.5, row: 0, col: 0, width: 4, fg: .red, track: .gray)
check("odd half-cells split one cell", split.splitCells.map(\.col), [2])
check("split cell left blank for the view", split.rows[0][2].ch, " ")
check("cell after split is track", split.rows[0][3].fg, .gray)

var box = Grid(cols: 6, rows: 3)
box.box(top: 0, bottom: 2, color: .orange)
check("box top", text(box, 0), "╭────╮")
check("box sides", text(box, 1), "│    │")
check("box bottom", text(box, 2), "╰────╯")

var under = Grid(cols: 4, rows: 1)
under.blockBar(30, row: 0, col: 0, width: 4, fg: .red, track: .gray)
// 30% of 32 eighths is 9.6 → 10: one full cell and a quarter.
check("block bar cells", text(under, 0), "█▎░░")
check("partial cell keeps its track", under.rows[0][1].under, .gray)
check("full cell has no track under it", under.rows[0][0].under, nil)

if failed { print("FAILED"); exit(1) }
print("all theme checks passed")
