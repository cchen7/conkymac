import AppKit
import ConkyMacCore
import CoreText
import Testing
@testable import ConkyMac

private let values = ConkyValues(snapshot: .fixture, utc: true)

/// Menlo at a pixel size keeps every glyph the same width, so positions can be checked exactly.
@MainActor
private func renderer(_ text: String, _ config: [String: String] = [:]) -> ConkyTextRenderer {
    var entries = ["font": "Menlo:pixelsize=10", "draw_shades": "false", "default_color": "white"]
    entries.merge(config) { _, new in new }
    return ConkyTextRenderer(text: text, settings: ConkySettings(config: entries))
}

private struct Placed { var width: Double; var x: Double; var baseline: Double }

private func texts(_ layout: TextLayout) -> [Placed] {
    layout.primitives.compactMap { primitive in
        guard case .text(let line, let x, let baseline, _) = primitive else { return nil }
        return Placed(width: CTLineGetTypographicBounds(line, nil, nil, nil), x: x, baseline: baseline)
    }
}

@MainActor @Test func cursorMovesLikeConky() {
    let inset = ConkySettings().textInset
    let text = renderer("ab${offset 7}cd${goto 90}ef\nline two")
    let placed = texts(text.layout(values: values))
    #expect(placed.count == 4)
    #expect(placed[0].x == inset)
    #expect(abs(placed[1].x - (inset + placed[0].width + 7)) < 1e-9)
    #expect(placed[2].x == 90) // goto is in window coordinates, not text coordinates
    #expect(placed[0].baseline == placed[2].baseline && placed[3].baseline > placed[0].baseline)
    #expect(placed[3].x == inset)
}

@MainActor @Test func alignrAndAlignc() {
    let right = renderer("ab${alignr 0}cd", ["minimum_width": "200"])
    let placed = texts(right.layout(values: values))
    let inset = right.settings.textInset
    // The remainder ends at the right edge of the text area: inset + width.
    #expect(abs(placed[1].x + placed[1].width - (inset + 200)) < 1e-9)
    #expect(placed[0].x == inset)
    // Conky's default offset for a bare ${alignr} is 1.
    let bare = texts(renderer("ab${alignr}cd", ["minimum_width": "200"]).layout(values: values))
    #expect(abs(bare[1].x + bare[1].width - (inset + 200 - 1)) < 1e-9)
    let center = renderer("${alignc}mid", ["minimum_width": "200"])
    let middle = texts(center.layout(values: values))[0]
    #expect(abs(middle.x + middle.width / 2 - (inset + 100)) < 1e-9)
    // An offset argument shifts alignr to the left.
    let shifted = texts(renderer("${alignr 10}cd", ["minimum_width": "200"]).layout(values: values))[0]
    #expect(abs(shifted.x + shifted.width - (inset + 200 - 10)) < 1e-9)
}

@MainActor @Test func linesAdvanceByFontHeightAndVoffsetAccumulates() {
    let metrics = NSFont(name: "Menlo-Regular", size: 10)!
    let height = metrics.ascender.rounded(.up) + (-metrics.descender).rounded(.up)
    let plain = texts(renderer("a\nb\nc").layout(values: values))
    #expect(abs((plain[1].baseline - plain[0].baseline) - height) < 1e-9)
    #expect(abs((plain[2].baseline - plain[1].baseline) - height) < 1e-9)
    // voffset moves the rest of the line and every later line (cur_y is cumulative).
    let shifted = texts(renderer("a\nb${voffset -3}c\nd").layout(values: values))
    #expect(abs(shifted[2].baseline - (shifted[1].baseline - 3)) < 1e-9)
    #expect(abs((shifted[3].baseline - shifted[2].baseline) - height) < 1e-9)
    // A blank line still takes a full line.
    let blank = texts(renderer("a\n\nb").layout(values: values))
    #expect(abs((blank[1].baseline - blank[0].baseline) - 2 * height) < 1e-9)
}

@MainActor @Test func barsRulesAndFill() {
    let theme = renderer("a ${cpubar 4,100}\nb ${cpubar cpu1}\n${hr 2}${stippled_hr 3}", ["minimum_width": "200"])
    let layout = theme.layout(values: values)
    let inset = theme.settings.textInset
    var bars: [CGRect] = [], fractions: [Double] = [], rules: [(CGRect, Double?)] = []
    for primitive in layout.primitives {
        switch primitive {
        case .bar(let rect, let fraction, _): bars.append(rect); fractions.append(fraction)
        case .rule(let rect, _, let stipple): rules.append((rect, stipple))
        default: break
        }
    }
    #expect(bars.count == 2 && bars[0].width == 100 && bars[0].height == 4)
    #expect(abs(fractions[0] - 0.14) < 1e-9 && abs(fractions[1] - 0.31) < 1e-9) // total CPU, then cpu1
    // A bar without a width fills the rest of the line up to the right edge, less one pixel.
    #expect(abs(bars[1].maxX - (inset + 200 - 1)) < 1e-9 && bars[1].height == theme.settings.defaultBarHeight)
    #expect(rules.count == 2 && rules[0].0.height == 2 && rules[0].1 == nil && rules[1].1 == 3)
}

@MainActor @Test func sizeOnlyGrows() {
    let theme = renderer("${if_match ${cpu cpu0} > 50}a very long line of text that is wide${else}short${endif}")
    _ = theme.layout(values: values) // cpu is 14: "short"
    let small = theme.size
    var busy = values
    busy.cpu = 0.9
    _ = theme.layout(values: busy)
    let large = theme.size
    #expect(large.width > small.width)
    _ = theme.layout(values: values) // back to short: the window does not shrink
    #expect(theme.size == large)
    // minimum_width and the margins always count: width = minimum + 2 * (3 + 1 + 1) + 1.
    #expect(renderer("x", ["minimum_width": "300"]).size.width == 311)
}

@MainActor @Test func hostileThemesStayBounded() {
    let wide = renderer("${goto 1e300}x\n${voffset 1e300}y\n${offset -1e300}z")
    _ = wide.layout(values: values)
    #expect(wide.size.width <= 1500 + 11 && wide.size.height <= 3000 + 10)
    #expect(wide.size.width.isFinite && wide.size.height.isFinite)
    // 30,000 objects on one line must not cost O(n^2) (alignr needs the width of the rest of the line).
    let many = renderer("${alignr}" + String(repeating: "${offset 1}x", count: 30_000))
    let start = Date()
    _ = many.layout(values: values)
    #expect(Date().timeIntervalSince(start) < 3)
    // A tall text keeps the window below the cap even with thousands of lines.
    let tall = renderer(String(repeating: "line\n", count: 5000))
    _ = tall.layout(values: values)
    #expect(tall.size.height <= 3000 + 10)
}

@MainActor @Test func blockedCommandsLeaveSpaceNotText() {
    var reported: [String] = []
    let theme = renderer("[${exec echo hi}][${cat /etc/passwd}]")
    let placed = texts(theme.layout(values: values) { reported.append($0) })
    #expect(placed.count == 1) // "[][]" only; nothing the commands could have produced
    #expect(reported.count == 2)
}
