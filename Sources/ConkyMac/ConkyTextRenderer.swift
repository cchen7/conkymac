import AppKit
import ConkyMacCore
import CoreText

/// What to draw for one `conky.text` pass, in window coordinates (origin top-left, y down).
struct TextLayout {
    enum Primitive {
        case text(CTLine, x: Double, baseline: Double, color: ConkyColor)
        case rule(CGRect, color: ConkyColor, stipple: Double?)
        case bar(CGRect, fraction: Double, color: ConkyColor)
    }
    var primitives: [Primitive] = []
}

/// Lays out and draws `conky.text` with CoreText, following conky.cc's cursor model: every line
/// starts at the text origin and advances by its font's ascent; `goto`, `offset`, `voffset`, `alignr`
/// and `alignc` move the cursor; bars and rules are sized against the rest of the line.
@MainActor
final class ConkyTextRenderer {
    let settings: ConkySettings
    private let nodes: [ConkyNode]
    /// Only grows: the text changes width every second, and a window that resized each time would shake.
    private(set) var size: NSSize
    private var contentWidth = 0.0
    private var contentHeight = 0.0
    /// Hard limits (points): a theme can ask for any size, and the bitmap behind it is 4 bytes per pixel at 2x.
    private static let maxWidth = 1500.0, maxHeight = 3000.0
    /// Cursor positions are clamped to ±this, far outside any bitmap but safe to hand to CoreGraphics.
    private static let far = 100_000.0
    /// Longest a rule, bar, graph or tab may be and tallest a bar or rule: wider than any window.
    private static let reach = maxWidth + 20
    private static let tallest = maxHeight
    private var fonts: [String: LoadedFont] = [:]
    private var lines: [String: CTLine] = [:]

    private struct LoadedFont { let font: CTFont; let ascent: Double; let descent: Double }

    init(text: String, settings: ConkySettings) {
        self.settings = settings
        nodes = ConkyTextParser.parse(text)
        size = NSSize(width: settings.minimumWidth + 2 * settings.textInset + 1, height: settings.minimumHeight + 2 * settings.textInset)
    }

    /// Evaluates the text for `values`, grows `size` if needed and returns what to draw.
    func layout(values: ConkyValues, report: (String) -> Void = { _ in }) -> TextLayout {
        let evaluated = ConkyText.lines(nodes, values: values, settings: settings, report: report)
        // Pass 1 finds the natural width (alignment and fill widths need it); pass 2 places everything.
        let natural = place(evaluated, width: nil)
        var width = max(settings.minimumWidth, natural.right - settings.textInset, contentWidth)
        if settings.maximumWidth > 0 { width = min(width, settings.maximumWidth) }
        width = min(width, Self.maxWidth)
        contentWidth = width
        let placed = place(evaluated, width: width)
        contentHeight = min(Self.maxHeight, max(contentHeight, placed.bottom - settings.textInset, settings.minimumHeight))
        let grown = NSSize(width: (width + 2 * settings.textInset + 1).rounded(.up),
                           height: (contentHeight + 2 * settings.textInset).rounded(.up))
        size = NSSize(width: max(size.width, grown.width), height: max(size.height, grown.height))
        return TextLayout(primitives: placed.primitives)
    }

    func draw(_ layout: TextLayout, in context: CGContext) {
        for primitive in layout.primitives {
            switch primitive {
            case .text(let line, let x, let baseline, let color):
                if settings.drawOutline {
                    let outline = ConkyColor.parse(settings.outlineColor) ?? ConkyColor(red: 0, green: 0, blue: 0)
                    for (dx, dy) in [(-1.0, -1.0), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)] {
                        drawLine(line, x: x + dx, baseline: baseline + dy, color: outline, in: context)
                    }
                } else if settings.drawShades {
                    drawLine(line, x: x + 1, baseline: baseline + 1, color: ConkyColor.parse(settings.shadeColor) ?? ConkyColor(red: 0, green: 0, blue: 0), in: context)
                }
                drawLine(line, x: x, baseline: baseline, color: color, in: context)
            case .rule(let rect, let color, let stipple):
                context.saveGState()
                context.setFillColor(cgColor(color))
                if let stipple {
                    // Dashes one pixel long with `stipple` pixels between them.
                    var x = rect.minX
                    // The dashes are bounded by the rule's width, which place() caps; bound the count too.
                    var dashes = 0
                    while x < rect.maxX && dashes < 4096 {
                        context.fill(CGRect(x: x, y: rect.minY, width: min(1, rect.maxX - x), height: rect.height))
                        x += 1 + stipple; dashes += 1
                    }
                } else { context.fill(rect) }
                context.restoreGState()
            case .bar(let rect, let fraction, let color):
                context.saveGState()
                context.setStrokeColor(cgColor(color))
                context.setFillColor(cgColor(color))
                context.setLineWidth(1)
                context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
                context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width * fraction, height: rect.height))
                context.restoreGState()
            }
        }
    }

    // MARK: Placement

    private func place(_ evaluated: [ConkyLine], width: Double?) -> (primitives: [TextLayout.Primitive], right: Double, bottom: Double) {
        let inset = settings.textInset
        var primitives: [TextLayout.Primitive] = []
        var right = inset
        var cursorY = inset
        let fallback = font(nil)
        let areaRight = width.map { inset + $0 }
        for line in evaluated {
            let fontsOnLine = line.map { font($0.style.font) }
            let ascent = fontsOnLine.map(\.ascent).max() ?? fallback.ascent
            let lastDescent = fontsOnLine.last?.descent ?? fallback.descent
            // Widths that alignr and alignc must reserve; goto, offset and rules do not count.
            let widths: [Double] = zip(line, fontsOnLine).map { item, font in
                switch item.kind {
                case .text(let text): return self.width(of: ctLine(text, font))
                case .bar(_, _, let barWidth), .graph(_, let barWidth): return barWidth
                default: return 0
                }
            }
            // restWidth[i]: what alignr and alignc must reserve after item i (one pass, not one per item).
            var restWidth = [Double](repeating: 0, count: widths.count + 1)
            for index in stride(from: widths.count - 1, through: 0, by: -1) { restWidth[index] = restWidth[index + 1] + widths[index] }
            cursorY += ascent
            var cursorX = inset
            var growth = 0.0
            for (index, item) in line.enumerated() {
                let font = fontsOnLine[index]
                let rest = restWidth[index + 1]
                switch item.kind {
                case .text(let text):
                    primitives.append(.text(ctLine(text, font), x: cursorX, baseline: cursorY, color: item.style.color))
                    cursorX += widths[index]
                case .goto(let x): cursorX = min(x, Self.far)
                case .offset(let dx): cursorX = max(-Self.far, min(Self.far, cursorX + dx))
                case .voffset(let dy): cursorY = max(-Self.far, min(Self.far, cursorY + dy))
                case .alignRight(let n): if let areaRight { cursorX = areaRight - rest - n }
                case .alignCenter(let n): if let width { cursorX = inset + (width - rest) / 2 - n }
                case .tab(let step, let start):
                    let step = min(max(1, step), Self.reach), start = min(max(0, start), Self.reach)
                    let relative = cursorX - inset
                    cursorX = relative < start ? inset + start : cursorX + step - (relative - start).truncatingRemainder(dividingBy: step)
                case .rule(let height, let ruleWidth, let stipple):
                    let length = min(Self.reach, ruleWidth > 0 ? ruleWidth : max(0, (areaRight ?? cursorX) - cursorX))
                    primitives.append(.rule(CGRect(x: cursorX, y: cursorY - ascent / 4, width: length, height: min(height, Self.tallest)),
                                            color: item.style.color, stipple: stipple.map { min($0, Self.reach) }))
                    cursorX += length
                case .bar(let fraction, let barHeight, let barWidth):
                    let height = min(barHeight, Self.tallest)
                    let length = min(Self.reach, barWidth > 0 ? barWidth : max(0, (areaRight ?? cursorX) - cursorX - 1))
                    var top = cursorY - ascent / 2 - 1
                    if height < font.ascent + font.descent { top -= height / 2 - 1 } else { growth = max(growth, height - (font.ascent + font.descent)) }
                    primitives.append(.bar(CGRect(x: cursorX, y: top, width: length, height: height), fraction: fraction, color: item.style.color))
                    cursorX += length
                case .graph(let graphHeight, let graphWidth):
                    cursorX += min(Self.reach, graphWidth > 0 ? graphWidth : max(0, (areaRight ?? cursorX) - cursorX - 1))
                    growth = max(growth, min(graphHeight, Self.tallest) - (font.ascent + font.descent))
                }
                right = max(right, cursorX)
            }
            cursorY = min(Self.far, cursorY + lastDescent + growth)
        }
        return (primitives, right, cursorY)
    }

    // MARK: Fonts and lines

    private func font(_ specification: String?) -> LoadedFont {
        let key = specification ?? ""
        if let cached = fonts[key] { return cached }
        let spec = ConkyFontSpec(specification ?? settings.font)
        let manager = NSFontManager.shared
        let alias = ["monospace": "Menlo", "mono": "Menlo", "sans": "Helvetica Neue", "sans-serif": "Helvetica Neue", "serif": "Times"][spec.family.lowercased()]
        let family = alias ?? spec.family
        var traits: NSFontTraitMask = []
        if spec.bold { traits.insert(.boldFontMask) }
        if spec.italic { traits.insert(.italicFontMask) }
        // A missing family falls back to Menlo for "mono" names (columns of spaces must still line up)
        // and to the system font otherwise; a missing icon font shows its letters.
        let resolved = manager.font(withFamily: family, traits: traits, weight: spec.bold ? 9 : 5, size: spec.pixelSize)
            ?? (family.lowercased().contains("mono") ? manager.font(withFamily: "Menlo", traits: traits, weight: spec.bold ? 9 : 5, size: spec.pixelSize) : nil)
            ?? NSFont.systemFont(ofSize: spec.pixelSize, weight: spec.bold ? .bold : .regular)
        let font = resolved as CTFont
        let loaded = LoadedFont(font: font, ascent: CTFontGetAscent(font).rounded(.up), descent: CTFontGetDescent(font).rounded(.up))
        if fonts.count >= 32 { fonts.removeAll(); lines.removeAll() }
        fonts[key] = loaded
        return loaded
    }

    private func ctLine(_ text: String, _ font: LoadedFont) -> CTLine {
        let key = "\(CTFontCopyPostScriptName(font.font))|\(CTFontGetSize(font.font))|\(text)"
        if let cached = lines[key] { return cached }
        // The colour comes from the context so one line serves the shadow, the outline and the text.
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font.font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        if lines.count >= 256 { lines.removeAll(keepingCapacity: true) }
        lines[key] = line
        return line
    }

    private func width(of line: CTLine) -> Double { CTLineGetTypographicBounds(line, nil, nil, nil) }

    private func drawLine(_ line: CTLine, x: Double, baseline: Double, color: ConkyColor, in context: CGContext) {
        context.saveGState()
        context.setFillColor(cgColor(color))
        context.textMatrix = .identity
        context.translateBy(x: x, y: baseline)
        context.scaleBy(x: 1, y: -1) // the target space is y-down; glyphs are y-up
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func cgColor(_ color: ConkyColor) -> CGColor {
        CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}
