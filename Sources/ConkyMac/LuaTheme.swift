import AppKit
import ConkyLuaBridge
import ConkyMacCore

@MainActor
protocol ThemeRenderer: AnyObject {
    var size: NSSize { get }
    var name: String { get }
    func draw(snapshot: Snapshot?, history: [Double?], background: Bool)
}

/// Themes are identified by a built-in id or an absolute Conky Lua .conf path.
/// User themes live in ~/Library/Application Support/ConkyMac/Themes/<name>/<name>.conf.
enum ThemeLibrary {
    static let defaultID = "simple"
    static let builtIns: [(id: String, name: String)] = [("simple", "Simple"), ("minimalis", "Minimalis")]

    /// nil for ids that are not built in (i.e. Lua .conf paths).
    @MainActor static func builtIn(_ id: String, fixedTimeZone: Bool = false) -> ThemeRenderer? {
        switch id {
        case "simple": SimpleTheme(fixedTimeZone: fixedTimeZone)
        case "minimalis": MinimalisTheme(fixedTimeZone: fixedTimeZone)
        default: nil
        }
    }

    static func displayName(id: String) -> String {
        builtIns.first { $0.id == id }?.name ?? displayName(id)
    }

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ConkyMac/Themes")
    }

    static func scan() -> [String] {
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return folders.flatMap { folder in
            ((try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
                .filter { $0.pathExtension == "conf" }.map(\.path)
        }.sorted()
    }

    static func displayName(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let folder = url.deletingLastPathComponent().lastPathComponent
        let file = url.deletingPathExtension().lastPathComponent
        return folder == file ? file : "\(folder)/\(file)"
    }
}

/// Owns the C bridge state. Closing it runs Lua finalizers only; it never calls back into Swift.
private final class LuaHandle {
    let pointer: OpaquePointer?
    init(_ pointer: OpaquePointer?) { self.pointer = pointer }
    deinit { conky_lua_close(pointer) }
}

/// conky_parse state, reached from C through an unretained pointer while LuaTheme is alive.
private final class TemplateContext {
    var values = ConkyValues(date: Date())
    private var warned: Set<String> = []
    private let diagnostics: Bool
    init(diagnostics: Bool) { self.diagnostics = diagnostics }

    func evaluate(_ text: String) -> String {
        ConkyTemplate.evaluate(text, values: values) { name in
            guard warned.count < 256, warned.insert(name).inserted, diagnostics else { return }
            FileHandle.standardError.write(Data("ConkyMac: unsupported conky_parse variable: \(name)\n".utf8))
        }
    }
}

/// A Conky Lua/Cairo theme. The hooks run once per snapshot into a bitmap shared by all views.
/// conky.text is not rendered; only lua_draw_hook_pre/post output appears.
@MainActor
final class LuaTheme: ThemeRenderer {
    let size: NSSize
    let name: String
    private let handle: LuaHandle
    private let template: TemplateContext
    private let fixedDate: Date?
    private let fixedScale: CGFloat?
    private var bitmap: CGContext?
    private var image: CGImage?
    private var renderedSequence: UInt64?
    private var renderedScale: CGFloat = 0
    private(set) var failure: String?
    private(set) var luaMilliseconds: [Double] = []
    // Fixed renders behave like a long-running instance: some scripts skip their first update.
    private var updates: Int

    init(path: String, fixedDate: Date? = nil, scale: CGFloat? = nil, diagnostics: Bool = false) {
        self.fixedDate = fixedDate
        fixedScale = scale
        updates = fixedDate == nil ? 0 : 99
        name = ThemeLibrary.displayName(path)
        let template = TemplateContext(diagnostics: diagnostics)
        self.template = template
        let context = Unmanaged.passUnretained(template).toOpaque()
        handle = LuaHandle(conky_lua_open(path, { context, text in
            guard let context else { return nil }
            let result = Unmanaged<TemplateContext>.fromOpaque(context).takeUnretainedValue().evaluate(String(cString: text))
            return result.isEmpty ? nil : strdup(result)
        }, context, fixedDate?.timeIntervalSince1970 ?? -1, 250))
        if let pointer = handle.pointer {
            size = NSSize(width: Int(conky_lua_width(pointer)), height: Int(conky_lua_height(pointer)))
            report(String(cString: conky_lua_error(pointer)))
        } else {
            size = NSSize(width: 300, height: 300)
            report("Out of memory while opening \(path)")
        }
    }

    func draw(snapshot: Snapshot?, history: [Double?], background: Bool) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = fixedScale ?? max(2, NSScreen.screens.map(\.backingScaleFactor).max() ?? 2)
        if image == nil || renderedSequence != (snapshot?.sequence ?? 0) || renderedScale != scale { render(snapshot, scale: scale) }
        let bounds = NSRect(origin: .zero, size: size)
        if background {
            NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
            bounds.fill()
        }
        if let image {
            context.saveGState()
            context.interpolationQuality = .high
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: bounds)
            context.restoreGState()
        }
        if let failure { drawFailure(failure, in: bounds) }
    }

    private func render(_ snapshot: Snapshot?, scale: CGFloat) {
        renderedSequence = snapshot?.sequence ?? 0
        renderedScale = scale
        guard let pointer = handle.pointer else { return }
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        if bitmap?.width != width || bitmap?.height != height {
            bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            // Conky/cairo user space: points, origin top-left, y down.
            bitmap?.translateBy(x: 0, y: CGFloat(height))
            bitmap?.scaleBy(x: scale, y: -scale)
        }
        guard let bitmap else { report("Cannot allocate a \(width)x\(height) bitmap"); return }
        bitmap.clear(CGRect(origin: .zero, size: size))
        updates += 1
        template.values = ConkyValues(date: fixedDate ?? Date(), utc: fixedDate != nil, cpu: snapshot?.cpuFraction, cores: snapshot?.coreFractions,
                                      memory: snapshot?.memory?.fraction, storage: snapshot?.storage?.fraction,
                                      battery: snapshot?.battery?.fraction, uptime: snapshot?.uptime, updates: updates)
        let start = ProcessInfo.processInfo.systemUptime
        let status = conky_lua_draw(pointer, bitmap)
        if luaMilliseconds.count >= 600 { luaMilliseconds.removeFirst() }
        luaMilliseconds.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        report(status == 0 ? "" : String(cString: conky_lua_error(pointer)))
        image = bitmap.makeImage()
    }

    private func report(_ message: String) {
        let next = message.isEmpty ? nil : message
        if let next, next != failure { FileHandle.standardError.write(Data("ConkyMac: Lua theme \(name): \(next)\n".utf8)) }
        failure = next
    }

    private func drawFailure(_ message: String, in bounds: NSRect) {
        // The traceback goes to stderr; the panel shows the message itself.
        let summary = message.components(separatedBy: "\nstack traceback:").first ?? message
        let text = NSAttributedString(string: "Lua theme error\n" + summary, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor(red: 1, green: 0.78, blue: 0.74, alpha: 1)])
        let area = bounds.insetBy(dx: 10, dy: 10)
        let height = min(area.height, text.boundingRect(with: area.size, options: .usesLineFragmentOrigin).height)
        NSColor(white: 0, alpha: 0.8).setFill()
        NSBezierPath(roundedRect: NSRect(x: area.minX - 5, y: area.minY - 5, width: area.width + 10, height: height + 10),
                     xRadius: 6, yRadius: 6).fill()
        text.draw(with: area, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
