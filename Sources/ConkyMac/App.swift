import AppKit
import ConkyMacCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let view = ThemeView()
    private var statusItem: NSStatusItem!
    private let sampler: SamplingService
    private var generation = 0
    private var sleeping = false
    private var hidden = false
    private var preview: Bool
    private var observers: [NSObjectProtocol] = []
    private let smokeSamples: Int?
    private let encoder = JSONEncoder()
    private var sampleCount = 0
    private let diagnose: Bool

    init(preview: Bool, interface: String?, smokeSamples: Int?, diagnose: Bool) {
        self.preview = preview; self.smokeSamples = smokeSamples; self.diagnose = diagnose
        sampler = SamplingService(interface: interface)
        super.init()
        encoder.dateEncodingStrategy = .iso8601
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: SimpleTheme.size),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.title = "ConkyMac — Simple"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = view
        configureWindow()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform.path", accessibilityDescription: "ConkyMac")
        statusItem.button?.toolTip = "ConkyMac"
        let menu = NSMenu()
        for (title, action, key) in [("Show on Desktop", #selector(showDesktop), ""),
                                      ("Preview", #selector(showPreview), "p"),
                                      ("Hide", #selector(hideMonitor), "h"),
                                      ("Quit ConkyMac", #selector(quit), "q")] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
        }
        statusItem.menu = menu
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleeping = true; self?.stopSampling() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleeping = false; self?.startSampling() }
        })
        startSampling()
    }

    private func configureWindow() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        view.previewBackground = preview
        window.styleMask = preview ? [.titled, .closable, .miniaturizable] : .borderless
        window.isOpaque = preview
        window.backgroundColor = preview ? NSColor(white: 0.12, alpha: 1) : .clear
        window.hasShadow = preview
        window.ignoresMouseEvents = !preview
        window.level = preview ? .normal : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        window.collectionBehavior = preview ? [.managed] : [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            window.setFrameTopLeftPoint(NSPoint(x: frame.minX + 15, y: frame.maxY - 15))
        }
        view.needsDisplay = true
        window.orderFrontRegardless()
        if preview { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    }

    private func startSampling() {
        guard !hidden, !sleeping else { return }
        generation += 1
        let expected = generation
        // Fresh baselines after hide or sleep. Old queued results are discarded.
        view.history = History(capacity: 120)
        sampler.start { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self, self.generation == expected, !self.hidden, !self.sleeping else { return }
                self.view.update(snapshot)
                self.sampleCount += 1
                if self.diagnose, let data = try? self.encoder.encode(snapshot) {
                    FileHandle.standardOutput.write(data + Data([10]))
                }
                if let maximum = self.smokeSamples, self.sampleCount >= maximum {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.quit() }
                }
            }
        }
    }

    private func stopSampling() { generation += 1; sampler.stop() }
    @objc private func showDesktop() { preview = false; show() }
    @objc private func showPreview() { preview = true; show() }
    private func show() {
        let wasHidden = hidden
        hidden = false; configureWindow()
        if wasHidden { startSampling() }
    }
    @objc private func hideMonitor() { hidden = true; window.orderOut(nil); stopSampling() }
    @objc private func quit() { NSApp.terminate(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hideMonitor(); return false }

    func applicationWillTerminate(_ notification: Notification) {
        stopSampling()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if diagnose {
            let values = view.drawMilliseconds.sorted()
            if !values.isEmpty {
                let p95 = values[min(values.count - 1, Int(Double(values.count - 1) * 0.95))]
                print("GUI_SUMMARY samples=\(sampleCount) draws=\(values.count) draw_p95_ms=\(String(format: "%.3f", p95)) mouse_passthrough=\(window.ignoresMouseEvents) level=\(window.level.rawValue)")
            }
        }
    }
}
