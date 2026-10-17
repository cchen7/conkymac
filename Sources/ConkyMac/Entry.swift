import AppKit
import ConkyMacCore

private struct Options {
    var preview = false
    var probe: Int?
    var smoke: Int?
    var render: String?
    var scale = 2
    var interface: String?
    var diagnose = false
    var sensors = false
    var iconMargin = 120.0
    /// A built-in theme id or an absolute Conky Lua .conf path; nil keeps the menu choice.
    var theme: String?

    init(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            func value() throws -> String {
                index += 1
                guard index < arguments.count else { throw CLIError.usage("Missing value for \(flag)") }
                return arguments[index]
            }
            switch flag {
            case "--preview": preview = true
            case "--diagnostics": diagnose = true
            case "--sensors": sensors = true
            case "--interface": interface = try value()
            case "--icon-margin":
                guard let number = Double(try value()), (0...600).contains(number) else { throw CLIError.usage("Icon margin must be 0...600 points") }
                iconMargin = number
            case "--render": render = try value()
            case "--theme":
                let path = try value()
                if ThemeLibrary.builtIns.contains(where: { $0.id == path.lowercased() }) { theme = path.lowercased(); break }
                let resolved = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
                guard FileManager.default.fileExists(atPath: resolved) else { throw CLIError.usage("Theme not found: \(path)") }
                theme = resolved
            case "--scale":
                guard let number = Int(try value()), (1...2).contains(number) else { throw CLIError.usage("Scale must be 1 or 2") }
                scale = number
            case "--probe", "--smoke":
                guard let number = Int(try value()), (2...3600).contains(number) else { throw CLIError.usage("Sample count must be 2...3600") }
                if flag == "--probe" { probe = number } else { smoke = number; diagnose = true }
            default: throw CLIError.usage("Unknown option: \(flag)")
            }
            index += 1
        }
        guard [probe != nil, smoke != nil, render != nil].filter({ $0 }).count <= 1 else {
            throw CLIError.usage("Use only one of --probe, --smoke or --render")
        }
    }
}

private enum CLIError: Error { case usage(String); case render; case lua(String) }

@main
struct ConkyMacMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--help") {
            print("ConkyMac [--preview] [--interface en0] [--diagnostics]\n  --sensors       Print what the temperature/frequency readers see on this Mac, then exit\n  --probe N       Print N real snapshots at 1 Hz, then exit\n  --smoke N       Run the GUI for N snapshots, then exit\n  --render PATH   Save a fixed-input PNG (dark preview background)\n  --scale 1|2     PNG pixel scale (default: 2)\n  --icon-margin N Extra right margin on the main display for desktop icons (default: 120)\n  --theme ID|PATH Built-in theme (simple-plus, simple, minimalis) or Conky Lua .conf (overrides the menu choice; also used by --render)")
            return
        }
        do {
            let options = try Options(Array(CommandLine.arguments.dropFirst()))
            if options.sensors {
                print(sensorDiagnostics())
                return
            }
            if let count = options.probe {
                let collector = SystemCollector(interface: options.interface)
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                for index in 0..<count {
                    let snapshot = collector.sample()
                    FileHandle.standardOutput.write(try encoder.encode(snapshot) + Data([10]))
                    if index + 1 < count { Thread.sleep(forTimeInterval: 1) }
                }
                return
            }
            if let path = options.render {
                try render(to: path, scale: options.scale, theme: options.theme, diagnostics: options.diagnose)
                return
            }
            let application = NSApplication.shared
            let delegate = AppDelegate(preview: options.preview, interface: options.interface, iconMargin: options.iconMargin,
                                       smokeSamples: options.smoke, diagnose: options.diagnose, theme: options.theme)
            application.delegate = delegate
            withExtendedLifetime(delegate) { application.run() }
        } catch CLIError.lua {
            exit(1)  // LuaTheme already reported the script error on stderr.
        } catch {
            FileHandle.standardError.write(Data("ConkyMac: \(error)\nUse --help for usage.\n".utf8))
            exit(1)
        }
    }

    @MainActor private static func render(to path: String, scale: Int, theme: String?, diagnostics: Bool) throws {
        // Without --theme the fixture renders Simple, keeping the recorded baseline hash meaningful.
        let id = theme ?? "simple"
        let renderer: ThemeRenderer = ThemeLibrary.builtIn(id, fixedTimeZone: true)
            ?? LuaTheme(path: id, fixedDate: Snapshot.fixture.sampledAt, scale: CGFloat(scale), diagnostics: diagnostics)
        let size = renderer.size
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
                                            pixelsHigh: Int(size.height) * scale, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CLIError.render }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        let flipped = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.current = flipped
        let history: [Double?] = (0..<120).map { index in 0.08 + Double((index * 17) % 23) / 100 }
        renderer.draw(snapshot: .fixture, history: history, background: true)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CLIError.render }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        if let failure = (renderer as? LuaTheme)?.failure { throw CLIError.lua(failure) }
        print("RENDER_OK \(path) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
    }
}
