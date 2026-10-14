import AppKit
import ConkyMacCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    /// Desktop mode: one window per display, top-right. Preview: one window on the primary display.
    private var windows: [NSWindow] = []
    private var views: [ThemeView] { windows.compactMap { $0.contentView as? ThemeView } }
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
    private let iconMargin: CGFloat
    private static let themeKey = "ThemePath"
    /// A built-in id (ThemeLibrary.builtIns) or a Conky Lua .conf path.
    private var themeID: String
    private var renderer: ThemeRenderer

    init(preview: Bool, interface: String?, iconMargin: Double, smokeSamples: Int?, diagnose: Bool, theme: String?) {
        self.preview = preview; self.smokeSamples = smokeSamples; self.diagnose = diagnose
        self.iconMargin = iconMargin
        sampler = SamplingService(interface: interface)
        // --theme wins; a remembered Lua theme that has since been deleted falls back to the default.
        // An empty saved value is the earlier encoding of Simple.
        let saved = UserDefaults.standard.string(forKey: Self.themeKey).map { $0.isEmpty ? "simple" : $0 }.flatMap {
            ThemeLibrary.builtIn($0) != nil || FileManager.default.fileExists(atPath: $0) ? $0 : nil
        }
        themeID = theme ?? saved ?? ThemeLibrary.defaultID
        renderer = Self.makeRenderer(themeID, diagnose: diagnose)
        super.init()
        encoder.dateEncodingStrategy = .iso8601
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureWindows()
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
        let themes = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themes.submenu = NSMenu(title: "Theme")
        themes.submenu?.delegate = self
        menu.insertItem(themes, at: 2)
        statusItem.menu = menu
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleeping = true; self?.stopSampling() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleeping = false; self?.startSampling() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            // Preview is a normal window the user may have moved; leave it alone.
            MainActor.assumeIsolated { if let self, !self.hidden, !self.preview { self.configureWindows() } }
        })
        startSampling()
    }

    private func configureWindows() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let count = preview ? min(1, screens.count) : screens.count
        while windows.count > count { windows.removeLast().orderOut(nil) }
        while windows.count < count {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: renderer.size),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.delegate = self
            let view = ThemeView(renderer: renderer)
            // A display added mid-session starts from the current state, not blank.
            if let existing = views.first { view.snapshot = existing.snapshot; view.history = existing.history }
            window.contentView = view
            windows.append(window)
        }
        for (index, (window, screen)) in zip(windows, screens).enumerated() {
            configure(window, on: screen, isMain: index == 0)
        }
    }

    private func configure(_ window: NSWindow, on screen: NSScreen, isMain: Bool) {
        guard let view = window.contentView as? ThemeView else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        view.previewBackground = preview
        window.styleMask = preview ? [.titled, .closable, .miniaturizable] : .borderless
        window.title = "ConkyMac — \(renderer.name)"
        window.setContentSize(renderer.size)
        window.isOpaque = preview
        window.backgroundColor = preview ? NSColor(white: 0.12, alpha: 1) : .clear
        window.hasShadow = preview
        window.ignoresMouseEvents = !preview
        window.level = preview ? .normal : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        window.collectionBehavior = preview ? [.managed] : [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let frame = screen.visibleFrame
        // Finder puts desktop icons in a right-hand column on the main display by default.
        let right = 15 + (isMain ? iconMargin : 0)
        let x = max(frame.minX + 15, frame.maxX - window.frame.width - right)
        window.setFrameTopLeftPoint(NSPoint(x: x, y: frame.maxY - 15))
        view.needsDisplay = true
        window.orderFrontRegardless()
        if preview { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    }

    private func startSampling() {
        guard !hidden, !sleeping else { return }
        generation += 1
        let expected = generation
        // Fresh baselines after hide or sleep. Old queued results are discarded.
        for view in views { view.history = History(capacity: 120) }
        sampler.start { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self, self.generation == expected, !self.hidden, !self.sleeping else { return }
                for view in self.views { view.update(snapshot) }
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

    private static func makeRenderer(_ id: String, diagnose: Bool) -> ThemeRenderer {
        ThemeLibrary.builtIn(id) ?? LuaTheme(path: id, diagnostics: diagnose)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        var ids = ThemeLibrary.builtIns.map(\.id) + ThemeLibrary.scan()
        if !ids.contains(themeID) { ids.append(themeID) }
        for id in ids {
            let item = menu.addItem(withTitle: ThemeLibrary.displayName(id: id), action: #selector(selectTheme(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.toolTip = ThemeLibrary.builtIn(id) == nil ? id : nil
            item.state = id == themeID ? .on : .off
        }
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        UserDefaults.standard.set(id, forKey: Self.themeKey)
        guard id != themeID else { return }
        themeID = id
        renderer = Self.makeRenderer(id, diagnose: diagnose)
        for view in views { view.renderer = renderer }
        if !hidden { configureWindows() }
    }
    @objc private func showDesktop() { preview = false; show() }
    @objc private func showPreview() { preview = true; show() }
    private func show() {
        let wasHidden = hidden
        hidden = false; configureWindows()
        if wasHidden { startSampling() }
    }
    @objc private func hideMonitor() { hidden = true; windows.forEach { $0.orderOut(nil) }; stopSampling() }
    @objc private func quit() { NSApp.terminate(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hideMonitor(); return false }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        ((notification.object as? NSWindow)?.contentView as? ThemeView)?.occlusionChanged()
        sampler.setDetailsWanted(windows.contains { $0.occlusionState.contains(.visible) })
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopSampling()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        if diagnose, let window = windows.first {
            let values = views.flatMap(\.drawMilliseconds).sorted()
            if !values.isEmpty {
                let p95 = values[min(values.count - 1, Int(Double(values.count - 1) * 0.95))]
                let frames = windows.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY))" }.joined(separator: ";")
                var lua = ""
                if let theme = renderer as? LuaTheme {
                    let times = theme.luaMilliseconds.sorted()
                    let p50 = times.isEmpty ? 0 : times[times.count / 2]
                    let p95 = times.isEmpty ? 0 : times[min(times.count - 1, Int(Double(times.count - 1) * 0.95))]
                    lua = " lua_evals=\(times.count) lua_p50_ms=\(String(format: "%.3f", p50)) lua_p95_ms=\(String(format: "%.3f", p95)) lua_error=\(theme.failure != nil)"
                }
                print("GUI_SUMMARY theme=\(renderer.name) samples=\(sampleCount) windows=\(windows.count) frames=\(frames) draws=\(values.count) skipped=\(views.map(\.skippedUpdates).reduce(0, +)) draw_p95_ms=\(String(format: "%.3f", p95)) mouse_passthrough=\(window.ignoresMouseEvents) level=\(window.level.rawValue)\(lua)")
            }
        }
    }
}
