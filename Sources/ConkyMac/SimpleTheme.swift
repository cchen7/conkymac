import AppKit
import ConkyMacCore
import CoreText

@MainActor
final class SimpleTheme {
    static let size = NSSize(width: 300, height: 912)
    private let foreground = NSColor(white: 0.96, alpha: 1)
    private let secondary = NSColor(white: 0.68, alpha: 1)
    private let accent = NSColor(red: 0.83, green: 0.66, blue: 1, alpha: 1)
    private let barColor = NSColor(red: 0.75, green: 0.79, blue: 0.80, alpha: 1)
    private let weekday = DateFormatter()
    private let date = DateFormatter()
    private let clock = DateFormatter()
    private var lines: [String: CTLine] = [:]
    private var icons: [String: NSImage] = [:]
    private let fontName: String

    init(fixedTimeZone: Bool = false) {
        fontName = !fixedTimeZone && NSFont(name: "IBMPlexMono", size: 12) != nil ? "IBMPlexMono" : "Menlo"
        for formatter in [weekday, date, clock] {
            formatter.locale = Locale(identifier: "en_US_POSIX")
            if fixedTimeZone { formatter.timeZone = TimeZone(secondsFromGMT: 0) }
        }
        weekday.dateFormat = "EEEE"
        date.dateFormat = "dd MMMM yyyy"
        clock.dateFormat = "HH:mm"
    }

    func draw(snapshot: Snapshot?, history: [Double?], background: Bool) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        if background {
            NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
            NSRect(origin: .zero, size: Self.size).fill()
        } else {
            // Transparent desktop mode: keep text legible on bright wallpapers.
            // One layer, so the whole panel casts a single shadow pass.
            context.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: NSColor(white: 0, alpha: 0.95).cgColor)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        defer { if !background { context.endTransparencyLayer() } }
        let now = snapshot?.sampledAt ?? Date()
        text(weekday.string(from: now).uppercased(), x: 20, y: 15, size: 25)
        text(date.string(from: now).uppercased(), x: 20, y: 51, size: 17)
        text(clock.string(from: now), x: 16, y: 82, size: 57)

        row("SYSTEM", value: nil, icon: "desktopcomputer", y: 172)
        text(snapshot?.systemVersion ?? "macOS", x: 44, y: 197, size: 12)

        let power = snapshot?.battery
        let batteryText = power.map { value in
            value.fraction.map { "\(value.state) · \(Int(($0 * 100).rounded()))%" } ?? value.state
        } ?? "N/A"
        row("BATTERY", value: batteryText, icon: "battery.100", y: 237, valueSize: 10)
        bar(fraction: power?.fraction, y: 264)
        row("UPTIME", value: snapshot?.uptime.map { uptime($0) } ?? "N/A", icon: "clock", y: 287, valueSize: 11)

        row("CPU", value: snapshot?.cpuFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "N/A", icon: "cpu", y: 327)
        graph(history, in: CGRect(x: 20, y: 354, width: 260, height: 28), context: context)
        row("FREQUENCY", value: "N/A", icon: "waveform", y: 399, valueSize: 11)
        row("TEMPERATURE", value: "N/A", icon: "thermometer.medium", y: 431, valueSize: 11)

        row("RAM", value: capacity(snapshot?.memory), icon: "memorychip", y: 474, valueSize: 11)
        bar(fraction: snapshot?.memory?.fraction, y: 501)
        row("STORAGE", value: capacity(snapshot?.storage), icon: "internaldrive", y: 530, valueSize: 11)
        bar(fraction: snapshot?.storage?.fraction, y: 557)

        row("NETWORK", value: nil, icon: "network", y: 598)
        row("INTERFACE", value: snapshot?.network?.interface ?? "N/A", icon: "point.3.connected.trianglepath.dotted", y: 628, size: 10, valueSize: 10)
        row("UPLOAD", value: rate(snapshot?.network?.uploadBytesPerSecond), icon: "arrow.up", y: 654, size: 10, valueSize: 10)
        row("DOWNLOAD", value: rate(snapshot?.network?.downloadBytesPerSecond), icon: "arrow.down", y: 680, size: 10, valueSize: 10)
        row("SESSION UP", value: snapshot?.network.map { bytes($0.sessionUploadBytes) } ?? "N/A", icon: "arrow.up.doc", y: 706, size: 10, valueSize: 10)
        row("SESSION DOWN", value: snapshot?.network.map { bytes($0.sessionDownloadBytes) } ?? "N/A", icon: "arrow.down.doc", y: 732, size: 10, valueSize: 10)

        row("PROCESSES", value: snapshot?.processes == nil ? "N/A" : nil, icon: "list.bullet.rectangle", y: 772)
        if let processes = snapshot?.processes {
            text("CPU", x: 212, y: 774, size: 9, color: secondary, right: true)
            text("MEM", x: 280, y: 774, size: 9, color: secondary, right: true)
            for (index, process) in processes.prefix(5).enumerated() {
                let y = 798 + CGFloat(index) * 20
                let name = process.name.count > 18 ? process.name.prefix(17) + "…" : process.name
                text(name, x: 44, y: y, size: 10)
                text(String(format: "%.1f%%", process.cpuPercent), x: 212, y: y, size: 10, right: true)
                text(bytes(process.memoryBytes), x: 280, y: y, size: 10, right: true)
            }
        }
    }

    private func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, color: NSColor? = nil, right: Bool = false) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let chosen = color ?? foreground
        let key = "\(size)|\(chosen.description)|\(string)"
        let line: CTLine
        if let cached = lines[key] { line = cached } else {
            let font = NSFont(name: fontName, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: chosen]))
            // Bounded cache includes static labels and recently displayed values.
            if lines.count >= 192 { lines.removeAll(keepingCapacity: true) }
            lines[key] = line
        }
        var ascent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, nil, nil)
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: right ? x - width : x, y: y + ascent)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func row(_ label: String, value: String?, icon: String, y: CGFloat, size: CGFloat = 12, valueSize: CGFloat = 12) {
        if icons[icon] == nil {
            let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [foreground]))
            icons[icon] = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        }
        icons[icon]?.draw(in: NSRect(x: 20, y: y + 1, width: 14, height: 14),
                          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        text(label, x: 44, y: y, size: size, color: secondary)
        if let value { text(value, x: 280, y: y + 1, size: valueSize, right: true) }
    }

    private func bar(fraction: Double?, y: CGFloat) {
        let rectangle = NSRect(x: 20, y: y, width: 260, height: 5)
        secondary.withAlphaComponent(0.7).setStroke()
        NSBezierPath(rect: rectangle.insetBy(dx: 0.5, dy: 0.5)).stroke()
        if let fraction {
            barColor.setFill()
            NSRect(x: 20, y: y, width: 260 * min(1, max(0, fraction)), height: 5).fill()
        }
    }

    private func graph(_ values: [Double?], in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.setStrokeColor(secondary.cgColor)
        context.setLineWidth(0.5)
        context.stroke(rect.insetBy(dx: 0.25, dy: 0.25))
        let plot = rect.insetBy(dx: 1, dy: 1)
        context.clip(to: plot)
        context.setStrokeColor(accent.cgColor)
        context.setLineWidth(1)
        let step = (plot.width - 1) / 119
        // Missing samples remain gaps rather than fabricated zero readings.
        for (index, value) in values.enumerated() {
            guard let value else { continue }
            let x = plot.maxX - 0.5 - CGFloat(values.count - 1 - index) * step
            context.move(to: CGPoint(x: x, y: plot.maxY))
            context.addLine(to: CGPoint(x: x, y: plot.maxY - max(1, value * plot.height)))
        }
        context.strokePath()
        context.restoreGState()
    }

    private func bytes(_ value: Double) -> String {
        if value >= pow(1024, 3) { return String(format: "%.1f GiB", value / pow(1024, 3)) }
        if value >= pow(1024, 2) { return String(format: "%.1f MiB", value / pow(1024, 2)) }
        if value >= 1024 { return String(format: "%.1f KiB", value / 1024) }
        return String(format: "%.0f B", value)
    }
    private func capacity(_ value: Capacity?) -> String {
        guard let value else { return "N/A" }
        return String(format: "%.1f/%.0f GiB", value.used / pow(1024, 3), value.total / pow(1024, 3))
    }
    private func rate(_ value: Double?) -> String { value.map { bytes($0) + "/s" } ?? "N/A" }
    private func uptime(_ seconds: Double) -> String {
        let value = Int(seconds)
        return "\(value / 86400)d \(value / 3600 % 24)h \(value / 60 % 60)m"
    }
}

@MainActor
final class ThemeView: NSView {
    override var isFlipped: Bool { true }
    let renderer: SimpleTheme
    var snapshot: Snapshot?
    var history = History(capacity: 120)
    var previewBackground = false
    private(set) var drawMilliseconds: [Double] = []

    init(fixed: Bool = false) {
        renderer = SimpleTheme(fixedTimeZone: fixed)
        super.init(frame: NSRect(origin: .zero, size: SimpleTheme.size))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("ConkyMac system monitor")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ value: Snapshot) {
        snapshot = value
        history.append(value.cpuFraction)
        setAccessibilityValue("CPU \(value.cpuFraction.map { String(format: "%.0f percent", $0 * 100) } ?? "unavailable")")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let start = ProcessInfo.processInfo.systemUptime
        renderer.draw(snapshot: snapshot, history: history.values, background: previewBackground)
        if drawMilliseconds.count >= 600 { drawMilliseconds.removeFirst() }
        drawMilliseconds.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
    }
}
