import ConkyLuaBridge
import CoreGraphics
import Foundation
import Testing

private final class Theme {
    let pointer: OpaquePointer
    let context: CGContext

    init(_ script: String, hook: String = "test", budget: Int32 = 250, config: String? = nil, files: [String: Data] = [:]) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("conkymac-bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try script.write(to: folder.appendingPathComponent("test.lua"), atomically: true, encoding: .utf8)
        let conf = config ?? "conky.config = { minimum_width = 100, minimum_height = 80, lua_load = 'test.lua', lua_draw_hook_pre = '\(hook)' }"
        try conf.write(to: folder.appendingPathComponent("test.conf"), atomically: true, encoding: .utf8)
        for (name, data) in files { try data.write(to: folder.appendingPathComponent(name)) }
        let opened = conky_lua_open(folder.appendingPathComponent("test.conf").path, { _, text in
            String(cString: text) == "${answer}" ? strdup("42") : nil
        }, nil, -1, budget)
        pointer = try #require(opened)
        context = try #require(CGContext(data: nil, width: 100, height: 80, bitsPerComponent: 8, bytesPerRow: 400,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: 80)
        context.scaleBy(x: 1, y: -1)
    }
    deinit { conky_lua_close(pointer) }

    var error: String { String(cString: conky_lua_error(pointer)) }
    func draw() -> Int32 { conky_lua_draw(pointer, context) }
    /// Alpha at a y-down pixel.
    func alpha(_ x: Int, _ y: Int) -> UInt8 { context.data!.load(fromByteOffset: y * 400 + x * 4 + 3, as: UInt8.self) }
}

private let prelude = """
function conky_test()
  local cr = cairo_create(cairo_xlib_surface_create(conky_window.display, conky_window.drawable, conky_window.visual, conky_window.width, conky_window.height))

"""

@Test func arcsTurnClockwiseInYDownSpaceLikeCairo() throws {
    let theme = try Theme(prelude + """
      cairo_set_line_width(cr, 6)
      cairo_arc(cr, 50, 40, 30, 0, math.pi / 2)
      cairo_stroke(cr)
    end
    """)
    #expect(theme.draw() == 0, "\(theme.error)")
    #expect(theme.alpha(80, 40) == 255)  // angle 0: right
    #expect(theme.alpha(50, 70) == 255)  // pi/2: below the centre
    #expect(theme.alpha(50, 10) == 0)
    #expect(theme.alpha(20, 40) == 0)
}

@Test func patternsOutliveDestroyWhileInUse() throws {
    let theme = try Theme(prelude + """
      local pattern = cairo_pattern_create_linear(0, 0, 100, 0)
      cairo_pattern_add_color_stop_rgba(pattern, 0, 1, 0, 0, 1)
      cairo_pattern_add_color_stop_rgba(pattern, 1, 0, 0, 1, 1)
      cairo_set_source(cr, pattern)
      cairo_pattern_destroy(pattern)
      pattern = nil
      collectgarbage()
      cairo_rectangle(cr, 10, 10, 20, 20)
      cairo_fill(cr)
      cairo_destroy(cr)
      cairo_destroy(cr)
    end
    """)
    #expect(theme.draw() == 0, "\(theme.error)")
    #expect(theme.alpha(20, 20) == 255)
    #expect(theme.alpha(50, 50) == 0)
}

@Test func unsupportedCairoCallsAreNamed() throws {
    let theme = try Theme(prelude + "  cairo_show_text(cr, 'x')\nend")
    #expect(theme.draw() != 0)
    #expect(theme.error.contains("unsupported cairo API 'cairo_show_text'"))
    #expect(theme.error.contains("test.lua:3:"))
}

@Test func scriptErrorsAreReportedAndRecoverable() throws {
    let theme = try Theme(prelude + """
      calls = (calls or 0) + 1
      if calls == 1 then error('first frame fails') end
      if conky_parse('${answer}') ~= '42' then error('conky_parse mismatch') end
      cairo_destroy(cr)
      cairo_stroke(cr)
    end
    """)
    #expect(theme.draw() != 0)
    #expect(theme.error.contains("first frame fails"))
    #expect(theme.draw() != 0)
    #expect(theme.error.contains("cairo_t used after cairo_destroy"), "\(theme.error)")
}

@Test func runawayScriptsHitTheTimeBudget() throws {
    let theme = try Theme("function conky_test() while true do end end", budget: 50)
    let start = Date()
    #expect(theme.draw() != 0)
    #expect(theme.error.contains("time budget"))
    #expect(Date().timeIntervalSince(start) < 1)
}

@Test func scriptsCannotAbsorbTheTimeBudget() throws {
    let caught = try Theme("function conky_test() while true do pcall(function() while true do end end) end end", budget: 50)
    let start = Date()
    #expect(caught.draw() != 0 && caught.error.contains("time budget"))
    #expect(Date().timeIntervalSince(start) < 1)
    // The normal check interval returns for the next frame.
    let recovered = try Theme("calls = 0\nfunction conky_test() calls = calls + 1; if calls == 1 then while true do pcall(function() while true do end end) end end end", budget: 50)
    #expect(recovered.draw() != 0)
    #expect(recovered.draw() == 0)
    // Finalizers run without hooks, so Lua __gc is refused and bridge metatables are locked.
    let finalizer = try Theme("function conky_test() setmetatable({}, {__gc = function() end}) end")
    #expect(finalizer.draw() != 0 && finalizer.error.contains("__gc"))
    let locked = try Theme(prelude + "  assert(getmetatable(cr) == 'locked')\n  assert(not pcall(setmetatable, cr, {}))\n  cairo_destroy(cr)\nend")
    #expect(locked.draw() == 0, "\(locked.error)")
}

@Test func loadErrorsAreReported() throws {
    #expect(try Theme("", config: "conky = nil").error.contains("conky.config table is missing"))
    #expect(try Theme("", config: "alignment top_right\nTEXT\n").error.contains("Conky 1.10+"))
    #expect(try Theme("x = = 1").error.contains("test.lua:1:"))
    let early = try Theme("cairo_paint(cairo_create(cairo_xlib_surface_create()))")
    #expect(early.error.contains("only possible while a Conky draw hook runs"))
    #expect(early.draw() != 0)
    let missing = try Theme("function conky_other() end")
    #expect(missing.draw() != 0)
    #expect(missing.error.contains("draw hook conky_test is not a function"))
    #expect(try Theme("assert(os.execute == nil and io == nil and os.date ~= nil)\nfunction conky_test() end").draw() == 0)
}

@Test func binaryChunksAreRejectedEverywhere() throws {
    // A precompiled chunk header; Lua must refuse it before parsing any bytecode.
    let binary = Data([0x1B, 0x4C, 0x75, 0x61, 0x54, 0x00]) + Data(repeating: 0, count: 32)
    let script = try Theme("", config: "conky.config = { lua_load = 'binary.lua', lua_draw_hook_pre = 'test' }",
                           files: ["binary.lua": binary])
    #expect(script.error.contains("attempt to load a binary chunk"))
    #expect(try Theme("", files: ["test.conf": binary]).error.contains("attempt to load a binary chunk"))
    let theme = try Theme("""
    local header = '\\27Lua' .. string.rep('\\0', 32)
    local binarypath = assert(package.searchpath('binary', package.path))
    assert(string.dump == nil)
    local chunk, message = load(header, 'x', 'b')
    assert(chunk == nil and message:find('binary chunk'), message)
    chunk, message = load(header, 'x', 'b', {})
    assert(chunk == nil and message:find('binary chunk'), message)
    chunk, message = loadfile(binarypath, 'b')
    assert(chunk == nil and message:find('binary chunk'), message)
    assert(not pcall(dofile, binarypath))
    local ok, failure = pcall(require, 'binary')
    assert(not ok and failure:find('binary chunk'), failure)
    assert(package.cpath == '' and package.loadlib == nil and #package.searchers == 2)
    assert(load('return 1 + 1')() == 2 and load('return x', 'x', 't', {x = 3})() == 3)
    function conky_test() end
    """, files: ["binary.lua": binary])
    #expect(theme.error.isEmpty, "\(theme.error)")
}

