import AppKit
import ConkyMacCore
import CoreText

/// Native take on "Minimalis Conky 1.3" (archit3x): blue section rules, label/value
/// columns and thin bars. Uses SF Symbols instead of the theme's ConkySymbols font,
/// P/E cluster rows instead of per-core rows, and a generic network section.
@MainActor
final class MinimalisTheme {
    static let size = NSSize(width: 340, height: 620)
    private let accent = NSColor(red: 0x17 / 255, green: 0x93 / 255, blue: 0xd1 / 255, alpha: 1)
    private let value = NSColor(white: 0.75, alpha: 1)
    private let right: CGFloat = 328
    private let indent: CGFloat = 40
    private let body: CGFloat = 10
    private var lines: [String: CTLine] = [:]
    private var icons: [String: NSImage] = [:]
    private let fontName: String

    init(fixedTimeZone: Bool = false) {
        fontName = !fixedTimeZone && NSFont(name: "RobotoMono-Regular", size: 10) != nil ? "RobotoMono-Regular" : "Menlo"
    }

    func draw(snapshot: Snapshot?, history: [Double?], background: Bool) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        if background {
            NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
            NSRect(origin: .zero, size: Self.size).fill()
        } else {
            context.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: NSColor(white: 0, alpha: 0.95).cgColor)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        defer { if !background { context.endTransparencyLayer() } }
        let s = snapshot

        header("macOS»", icon: "applelogo", y: 10)
        pair("OS     :", s?.systemVersion ?? "N/A", y: 36)
        pair("Kernel :", s?.kernel ?? "N/A", y: 51)

        header("System»", icon: "cpu", y: 84)
        let frequency = s?.frequency, load = s?.clusterLoad
        meter("P-Cores:", ghz(frequency?.performanceMHz), fraction: load?.performance, y: 110)
        meter("E-Cores:", ghz(frequency?.efficiencyMHz), fraction: load?.efficiency, y: 125)
        pair("Uptime :", s?.uptime.map(uptime) ?? "N/A", y: 146)
        pair("Load :", s?.loadAverage.map { $0.map { String(format: "%.2f", $0) }.joined(separator: " ") } ?? "N/A",
             y: 146, alignRight: true)

        header("Temperature»", icon: "thermometer.medium", y: 179)
        pair("CPU :", celsius(s?.temperatureCelsius), y: 205)
        pair("GPU :", celsius(s?.gpuTemperatureCelsius), y: 205, alignRight: true)

        header("Memory»", icon: "memorychip", y: 238)
        meter("RAM :", capacity(s?.memory), fraction: s?.memory?.fraction, y: 264)
        meter("SWAP:", capacity(s?.swap), fraction: s?.swap.map { $0.total > 0 ? $0.fraction : 0 }, y: 279)

        header("Processes»", icon: "list.bullet.rectangle", y: 312)
        text("CPU usage", x: indent, y: 338, color: accent)
        text("Memory Usage", x: right, y: 338, color: accent, alignRight: true)
        stippledRule(y: 355, context: context)
        let byCPU = s?.processes ?? [], byMemory = s?.processesByMemory ?? []
        for index in 0..<5 {
            let y = 362 + CGFloat(index) * 15
            if index < byCPU.count {
                text(fitted(byCPU[index].name, width: 92), x: indent, y: y)
                text(String(format: "%.1f%%", byCPU[index].cpuPercent), x: 180, y: y, alignRight: true)
            }
            if index < byMemory.count {
                text(fitted(byMemory[index].name, width: 84), x: 192, y: y)
                text(bytes(byMemory[index].memoryBytes), x: right, y: y, alignRight: true)
            }
        }
        if s?.processes == nil { text("N/A", x: indent, y: 362) }
        let total = s?.processCount.map(String.init) ?? "N/A"
        var x = indent + text("Processes:", x: indent, y: 441, color: accent) + 6
        x += text(total, x: x, y: 441) + 10
        x += text("Running:", x: x, y: 441, color: accent) + 6
        text(s?.runningProcessCount.map(String.init) ?? "N/A", x: x, y: 441)

        header("Storage»", icon: "internaldrive", y: 474)
        meter("DATA :", capacity(s?.storage), fraction: s?.storage?.fraction, y: 500)

        header("Network»", icon: "network", y: 533)
        let network = s?.network
        pair("Interface     :", network?.interface ?? "N/A", y: 559)
        pair("Total Down/Up :", network.map { "\(bytes($0.sessionDownloadBytes))/\(bytes($0.sessionUploadBytes))" } ?? "N/A", y: 574)
        pair("Speed Down/Up :", network.map { "\(rate($0.downloadBytesPerSecond))/\(rate($0.uploadBytesPerSecond))" } ?? "N/A", y: 589)
    }

    private func header(_ title: String, icon name: String, y: CGFloat) {
        if icons[name] == nil {
            let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [accent]))
            icons[name] = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        }
        icons[name]?.draw(in: NSRect(x: 12, y: y, width: 20, height: 20), from: .zero, operation: .sourceOver,
                          fraction: 1, respectFlipped: true, hints: nil)
        let width = text(title, x: indent, y: y + 3, size: 11, color: accent)
        accent.setFill()
        NSRect(x: indent + width + 6, y: y + 10, width: max(0, right - indent - width - 6), height: 1).fill()
    }

    /// Label in the accent colour followed by a grey value, like `${color1}Label ${color}value`.
    private func pair(_ label: String, _ content: String, y: CGFloat, alignRight: Bool = false) {
        if alignRight {
            let width = text(content, x: right, y: y, alignRight: true)
            text(label, x: right - width - 6, y: y, color: accent, alignRight: true)
        } else {
            let width = text(label, x: indent, y: y, color: accent)
            text(content, x: indent + width + 6, y: y)
        }
    }

    /// `label value ... NN% [bar]`, the theme's `${alignr}$perc% ${bar 4,100}` rows.
    private func meter(_ label: String, _ content: String, fraction: Double?, y: CGFloat) {
        pair(label, content, y: y)
        let barX = right - 90
        text(fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "N/A", x: barX - 6, y: y, alignRight: true)
        let frame = NSRect(x: barX, y: y + 4, width: 90, height: 5)
        value.withAlphaComponent(0.8).setStroke()
        NSBezierPath(rect: frame.insetBy(dx: 0.5, dy: 0.5)).stroke()
        if let fraction {
            value.setFill()
            NSRect(x: barX, y: y + 4, width: 90 * min(1, max(0, fraction)), height: 5).fill()
        }
    }

    private func stippledRule(y: CGFloat, context: CGContext) {
        context.saveGState()
        context.setStrokeColor(accent.cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [1, 2])
        context.move(to: CGPoint(x: indent, y: y + 0.5))
        context.addLine(to: CGPoint(x: right, y: y + 0.5))
        context.strokePath()
        context.restoreGState()
    }

    private func font(_ size: CGFloat) -> NSFont {
        NSFont(name: fontName, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    @discardableResult
    private func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat? = nil, color: NSColor? = nil,
                      alignRight: Bool = false) -> CGFloat {
        guard let context = NSGraphicsContext.current?.cgContext else { return 0 }
        let size = size ?? body
        let chosen = color ?? value
        let key = "\(size)|\(chosen.description)|\(string)"
        let line: CTLine
        if let cached = lines[key] { line = cached } else {
            line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font(size), .foregroundColor: chosen]))
            if lines.count >= 256 { lines.removeAll(keepingCapacity: true) }
            lines[key] = line
        }
        var ascent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, nil, nil))
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: alignRight ? x - width : x, y: y + ascent)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
        return width
    }

    private func fitted(_ string: String, width: CGFloat) -> String {
        func measure(_ value: String) -> CGFloat {
            CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [.font: font(body)])), nil, nil, nil)
        }
        guard measure(string) > width else { return string }
        var characters = Array(string)
        while !characters.isEmpty && measure(String(characters) + "…") > width { characters.removeLast() }
        return String(characters) + "…"
    }

    private func ghz(_ megahertz: Double?) -> String { megahertz.map { String(format: "%.2fGHz", $0 / 1000) } ?? "idle" }
    private func celsius(_ value: Double?) -> String { value.map { String(format: "%.1f°C", $0) } ?? "N/A" }
    private func bytes(_ value: Double) -> String {
        if value >= pow(1024, 3) { return String(format: "%.1fGiB", value / pow(1024, 3)) }
        if value >= pow(1024, 2) { return String(format: "%.1fMiB", value / pow(1024, 2)) }
        if value >= 1024 { return String(format: "%.1fKiB", value / 1024) }
        return String(format: "%.0fB", value)
    }
    private func capacity(_ value: Capacity?) -> String {
        value.map { "\(bytes($0.used))/\(bytes($0.total))" } ?? "N/A"
    }
    private func rate(_ value: Double?) -> String { value.map(bytes) ?? "N/A" }
    private func uptime(_ seconds: Double) -> String {
        let value = Int(seconds)
        return "\(value / 86400)d \(value / 3600 % 24)h \(value / 60 % 60)m"
    }
}
