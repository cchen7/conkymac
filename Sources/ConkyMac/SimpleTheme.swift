import AppKit
import ConkyMacCore
import CoreText

@MainActor
final class SimpleTheme: ThemeRenderer {
    /// classic: the Simple-Conky-theme sidebar. plus: Simple's date and clock over the
    /// Minimalis sections (minus its OS/kernel block), drawn in Simple's style.
    enum Layout { case classic, plus }
    static let size = NSSize(width: 300, height: 912)
    static let plusSize = NSSize(width: 300, height: 812)
    private let layout: Layout
    var size: NSSize { layout == .classic ? Self.size : Self.plusSize }
    var name: String { layout == .classic ? "Simple" : "Simple Plus" }
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

    init(fixedTimeZone: Bool = false, layout: Layout = .classic) {
        self.layout = layout
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
            NSRect(origin: .zero, size: size).fill()
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
        if layout == .plus { drawPlus(snapshot); return }

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
        row("FREQUENCY", value: frequency(snapshot?.frequency), icon: "waveform", y: 399, valueSize: 11)
        row("TEMPERATURE", value: snapshot?.temperatureCelsius.map { String(format: "%.0f°C", $0) } ?? "N/A",
            icon: "thermometer.medium", y: 431, valueSize: 11)

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
                text(fitted(process.name, size: 10, width: 124), x: 44, y: y, size: 10)
                text(String(format: "%.1f%%", process.cpuPercent), x: 212, y: y, size: 10, right: true)
                text(bytes(process.memoryBytes), x: 280, y: y, size: 10, right: true)
            }
        }
    }

    private func drawPlus(_ snapshot: Snapshot?) {
        let frequency = snapshot?.frequency, load = snapshot?.clusterLoad
        func cluster(_ megahertz: Double?, _ fraction: Double?) -> String {
            let speed = megahertz.map { String(format: "%.2f GHz", $0 / 1000) } ?? "idle"
            return fraction.map { "\(speed) · \(Int(($0 * 100).rounded()))%" } ?? speed
        }
        row("SYSTEM", value: nil, icon: "cpu", y: 172)
        row("P-CORES", value: cluster(frequency?.performanceMHz, load?.performance), icon: "bolt", y: 198, size: 10, valueSize: 10)
        bar(fraction: load?.performance, y: 219)
        row("E-CORES", value: cluster(frequency?.efficiencyMHz, load?.efficiency), icon: "leaf", y: 232, size: 10, valueSize: 10)
        bar(fraction: load?.efficiency, y: 253)
        row("UPTIME", value: snapshot?.uptime.map { uptime($0) } ?? "N/A", icon: "clock", y: 266, size: 10, valueSize: 10)
        row("LOAD", value: snapshot?.loadAverage.map { $0.map { String(format: "%.2f", $0) }.joined(separator: " ") } ?? "N/A",
            icon: "gauge.with.dots.needle.33percent", y: 290, size: 10, valueSize: 10)

        func celsius(_ value: Double?) -> String { value.map { String(format: "%.0f°C", $0) } ?? "N/A" }
        row("TEMPERATURE", value: "CPU \(celsius(snapshot?.temperatureCelsius)) · GPU \(celsius(snapshot?.gpuTemperatureCelsius))",
            icon: "thermometer.medium", y: 328, valueSize: 11)

        row("MEMORY", value: nil, icon: "memorychip", y: 366)
        row("RAM", value: capacity(snapshot?.memory), icon: "square.stack.3d.up", y: 392, size: 10, valueSize: 10)
        bar(fraction: snapshot?.memory?.fraction, y: 413)
        let swap = snapshot?.swap
        row("SWAP", value: swap.map { "\(bytes($0.used))/\(bytes($0.total))" } ?? "N/A", icon: "arrow.left.arrow.right",
            y: 426, size: 10, valueSize: 10)
        bar(fraction: swap.map { $0.total > 0 ? $0.fraction : 0 }, y: 447)

        row("PROCESSES", value: snapshot?.processes == nil ? "N/A" : nil, icon: "list.bullet.rectangle", y: 484)
        if let byCPU = snapshot?.processes {
            text("BY CPU", x: 20, y: 510, size: 9, color: secondary)
            text("BY MEMORY", x: 158, y: 510, size: 9, color: secondary)
            let byMemory = snapshot?.processesByMemory ?? []
            for index in 0..<5 {
                let y = 528 + CGFloat(index) * 20
                if index < byCPU.count {
                    text(fitted(byCPU[index].name, size: 10, width: 84), x: 20, y: y, size: 10)
                    text(String(format: "%.1f%%", byCPU[index].cpuPercent), x: 146, y: y, size: 10, right: true)
                }
                if index < byMemory.count {
                    text(fitted(byMemory[index].name, size: 10, width: 60), x: 158, y: y, size: 10)
                    text(bytes(byMemory[index].memoryBytes), x: 280, y: y, size: 10, right: true)
                }
            }
            let counts = [snapshot?.processCount.map { "\($0) processes" }, snapshot?.runningProcessCount.map { "\($0) running" }]
            text(counts.compactMap { $0 }.joined(separator: " · "), x: 20, y: 630, size: 10, color: secondary)
        }

        row("STORAGE", value: capacity(snapshot?.storage), icon: "internaldrive", y: 664, valueSize: 11)
        bar(fraction: snapshot?.storage?.fraction, y: 691)

        let network = snapshot?.network
        row("NETWORK", value: network?.interface ?? "N/A", icon: "network", y: 724, valueSize: 11)
        row("SPEED", value: network.map { "↓ \(rate($0.downloadBytesPerSecond))  ↑ \(rate($0.uploadBytesPerSecond))" } ?? "N/A",
            icon: "arrow.up.arrow.down", y: 754, size: 10, valueSize: 10)
        row("TOTAL", value: network.map { "↓ \(bytes($0.sessionDownloadBytes))  ↑ \(bytes($0.sessionUploadBytes))" } ?? "N/A",
            icon: "sum", y: 780, size: 10, valueSize: 10)
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

    /// Truncates by rendered width, so wide (e.g. CJK) names cannot run into the CPU column.
    private func fitted(_ string: String, size: CGFloat, width: CGFloat) -> String {
        let font = NSFont(name: fontName, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        func measure(_ value: String) -> CGFloat {
            CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [.font: font])), nil, nil, nil)
        }
        guard measure(string) > width else { return string }
        var characters = Array(string)
        while !characters.isEmpty && measure(String(characters) + "…") > width { characters.removeLast() }
        return String(characters) + "…"
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
    private func frequency(_ value: CPUFrequency?) -> String {
        guard let value else { return "N/A" }
        func ghz(_ megahertz: Double?) -> String { megahertz.map { String(format: "%.2f", $0 / 1000) } ?? "idle" }
        return "P \(ghz(value.performanceMHz)) · E \(ghz(value.efficiencyMHz)) GHz"
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
    var renderer: ThemeRenderer { didSet { needsDisplay = true } }
    var snapshot: Snapshot?
    var history = History(capacity: 120)
    var previewBackground = false
    private(set) var drawMilliseconds: [Double] = []
    private(set) var skippedUpdates = 0
    private var stale = false

    init(renderer: ThemeRenderer) {
        self.renderer = renderer
        super.init(frame: NSRect(origin: .zero, size: renderer.size))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("ConkyMac system monitor")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ value: Snapshot) {
        snapshot = value
        history.append(value.cpuFraction)
        setAccessibilityValue("CPU \(value.cpuFraction.map { String(format: "%.0f percent", $0 * 100) } ?? "unavailable")")
        // A desktop panel is usually covered by other windows; draw only what can be seen.
        if window?.occlusionState.contains(.visible) ?? true {
            needsDisplay = true
        } else {
            stale = true
            skippedUpdates += 1
        }
    }

    func occlusionChanged() {
        guard stale, window?.occlusionState.contains(.visible) == true else { return }
        stale = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let start = ProcessInfo.processInfo.systemUptime
        renderer.draw(snapshot: snapshot, history: history.values, background: previewBackground)
        if drawMilliseconds.count >= 600 { drawMilliseconds.removeFirst() }
        drawMilliseconds.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
    }
}
