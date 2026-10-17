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
    /// Sum of alpha over x in xs and y in ys (y-down pixels).
    func ink(_ xs: Range<Int>, _ ys: Range<Int>) -> Int { ys.reduce(0) { sum, y in sum + xs.reduce(0) { $0 + Int(alpha($1, y)) } } }
    func ink() -> Int { ink(0..<100, 0..<80) }
    /// Mean x of the alpha-weighted pixels in the rows.
    func centroid(_ ys: Range<Int>) -> Double {
        let total = ink(0..<100, ys)
        return Double(ys.reduce(0) { sum, y in sum + (0..<100).reduce(0) { $0 + $1 * Int(alpha($1, y)) } }) / Double(max(total, 1))
    }
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
    let theme = try Theme(prelude + "  cairo_mask(cr, nil)\nend")
    #expect(theme.draw() != 0)
    #expect(theme.error.contains("unsupported cairo API 'cairo_mask'"))
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


// MARK: Text, clip, operators and dashes

private let textPrelude = prelude + "  cairo_select_font_face(cr, 'Helvetica', CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)\n"

/// Runs `body` after the text prelude and requires success.
private func run(_ body: String) throws -> Theme {
    let theme = try Theme(textPrelude + body + "\nend")
    #expect(theme.draw() == 0, "\(theme.error)")
    return theme
}

@Test func textIsAnchoredAtTheBaselineAndRightWayUp() throws {
    let theme = try run("""
      cairo_set_font_size(cr, 40)
      cairo_move_to(cr, 10, 60)
      cairo_show_text(cr, 'H')
    """)
    // Cap height of Helvetica at 40 pt is about 29 px: the glyph fills the rows above the baseline only.
    #expect(theme.ink(0..<100, 31..<60) > 0)
    #expect(theme.ink(0..<100, 62..<80) == 0)
    #expect(theme.ink(0..<100, 0..<26) == 0)
    #expect(theme.ink(0..<10, 0..<80) == 0)
    // Two vertical stems joined by a bar: the top rows are the stems only, the middle has more ink.
    #expect(theme.ink(0..<100, 44..<48) > theme.ink(0..<100, 33..<37))
}

@Test func textExtentsFollowCairo() throws {
    let theme = try Theme(textPrelude + """
      cairo_set_font_size(cr, 20)
      local e, f = cairo_text_extents_t:create(), cairo_font_extents_t.create()
      tolua.takeownership(e)
      tolua.takeownership(f)
      cairo_text_extents(cr, 'Hello', e)
      cairo_font_extents(cr, f)
      assert(e.width > 0 and e.height > 0 and e.x_advance > 0, 'sizes')
      assert(e.y_bearing < 0 and e.y_bearing > -20 and e.y_advance == 0, 'bearing')
      assert(f.ascent > 0 and f.descent > 0 and f.height >= f.ascent + f.descent and f.max_x_advance > 0, 'font')
      local longer = cairo_text_extents_t:create()
      cairo_text_extents(cr, 'Hello, world', longer)
      assert(longer.width > e.width and longer.x_advance > e.x_advance, 'longer')
      local single = cairo_text_extents_t:create()
      cairo_text_extents(cr, 'H', single)
      cairo_set_font_size(cr, 40)
      local double = cairo_text_extents_t:create()
      cairo_text_extents(cr, 'H', double)
      assert(math.abs(double.x_advance / single.x_advance - 2) < 0.05, 'doubling')
      assert(math.abs(double.width / single.width - 2) < 0.1, 'doubling width')
      cairo_text_extents(cr, '', e)
      assert(e.width == 0 and e.x_advance == 0)
      tolua.releaseownership(e)
      cairo_text_extents_t:destroy(e)
      cairo_destroy(cr)
    end
    """)
    #expect(theme.draw() == 0, "\(theme.error)")
}

@Test func showTextAndTextPathPlusFillAgree() throws {
    let shown = try run("cairo_set_font_size(cr, 30)\ncairo_move_to(cr, 10, 55)\ncairo_show_text(cr, 'Hay')")
    let pathed = try run("cairo_set_font_size(cr, 30)\ncairo_move_to(cr, 10, 55)\ncairo_text_path(cr, 'Hay')\ncairo_fill(cr)")
    #expect(shown.ink() > 0)
    #expect(shown.ink() == pathed.ink())
    // show_text leaves no path behind; text_path keeps one until it is filled or cleared.
    let kept = try run("""
      cairo_set_font_size(cr, 30)
      cairo_move_to(cr, 10, 55)
      cairo_show_text(cr, 'Hay')
      cairo_fill(cr)
    """)
    #expect(kept.ink() == shown.ink())
}

@Test func showTextMovesTheCurrentPoint() throws {
    _ = try run("""
      local x0, y0 = cairo_get_current_point(cr)
      assert(x0 == 0 and y0 == 0, 'no current point reads as 0,0')
      cairo_set_font_size(cr, 20)
      local e = cairo_text_extents_t:create()
      cairo_text_extents(cr, 'Hello', e)
      cairo_translate(cr, 3, 4)
      cairo_move_to(cr, 10, 50)
      cairo_show_text(cr, 'Hello')
      local x, y = cairo_get_current_point(cr)
      assert(math.abs(x - (10 + e.x_advance)) < 1e-6 and math.abs(y - 50) < 1e-6, x .. ',' .. y)
      cairo_show_text(cr, 'Hello')
      x = cairo_get_current_point(cr)
      assert(math.abs(x - (10 + 2 * e.x_advance)) < 1e-6)
      cairo_rel_line_to(cr, 5, 0)  -- continues from the text point
      x, y = cairo_get_current_point(cr)
      assert(math.abs(x - (15 + 2 * e.x_advance)) < 1e-6 and y == 50)
      cairo_new_path(cr)
      x, y = cairo_get_current_point(cr)
      assert(x == 0 and y == 0)
    """)
}

@Test func fontFacesAndFallbacks() throws {
    let regular = try run("cairo_set_font_size(cr, 30)\ncairo_move_to(cr, 10, 50)\ncairo_show_text(cr, 'Hl')")
    let bold = try Theme(textPrelude + """
      cairo_select_font_face(cr, 'Helvetica', CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
      cairo_set_font_size(cr, 30)
      cairo_move_to(cr, 10, 50)
      cairo_show_text(cr, 'Hl')
    end
    """)
    #expect(bold.draw() == 0, "\(bold.error)")
    #expect(bold.ink() > regular.ink())
    // Oblique leans right: relative to the upright face, the top of the 'l' moves right of its foot.
    func lean(_ slant: Int) throws -> Double {
        let theme = try Theme(textPrelude + """
          cairo_select_font_face(cr, 'Menlo', \(slant), CAIRO_FONT_WEIGHT_NORMAL)
          cairo_set_font_size(cr, 40)
          cairo_move_to(cr, 10, 60)
          cairo_show_text(cr, 'l')
        end
        """)
        #expect(theme.draw() == 0, "\(theme.error)")
        #expect(theme.ink() > 0)
        return theme.centroid(32..<40) - theme.centroid(52..<60)
    }
    let upright = try lean(0)
    #expect(try lean(2) > upright + 3)
    // Generic and unknown names, italic, and a CJK character that Helvetica lacks.
    let names = try run("""
      for _, name in ipairs({'sans', 'Sans', 'sans-serif', 'serif', 'monospace', 'Menlo', 'No Such Font 123', ''}) do
        for _, slant in ipairs({0, 1, 2}) do
          cairo_select_font_face(cr, name, slant, 1)
          cairo_set_font_size(cr, 12)
          local e = cairo_text_extents_t:create()
          cairo_text_extents(cr, 'Hello', e)
          assert(e.x_advance > 0, name)
        end
      end
    """)
    #expect(names.ink() == 0)
    let cjk = try run("cairo_set_font_size(cr, 30)\ncairo_move_to(cr, 10, 50)\ncairo_show_text(cr, '中文')")
    #expect(cjk.ink() > 0)
}

@Test func textHonoursColoursGradientsAndTransforms() throws {
    let red = try run("cairo_set_source_rgb(cr, 1, 0, 0)\ncairo_set_font_size(cr, 40)\ncairo_move_to(cr, 10, 60)\ncairo_show_text(cr, 'H')")
    let data = red.context.data!
    let stem = try #require((0..<100).first { red.alpha($0, 40) == 255 })  // inside the left stem
    let offset = 40 * 400 + stem * 4
    #expect(stem >= 10 && data.load(fromByteOffset: offset, as: UInt8.self) == 255 && data.load(fromByteOffset: offset + 1, as: UInt8.self) == 0)
    let gradient = try run("""
      local p = cairo_pattern_create_linear(0, 0, 100, 0)
      cairo_pattern_add_color_stop_rgba(p, 0, 0, 0, 0, 0)
      cairo_pattern_add_color_stop_rgba(p, 1, 0, 0, 0, 1)
      cairo_set_source(cr, p)
      cairo_set_font_size(cr, 40)
      cairo_move_to(cr, 10, 60)
      cairo_show_text(cr, 'HH')
    """)
    #expect(gradient.ink(0..<100, 0..<80) > 0)
    #expect(gradient.ink(40..<70, 0..<80) > gradient.ink(10..<39, 0..<80) * 3 / 2)  // the second H is more opaque
    // Scale and translate act on glyphs and the pen position alike; the baseline is a user-space y.
    let scaled = try run("cairo_translate(cr, 10, 0)\ncairo_scale(cr, 2, 2)\ncairo_set_font_size(cr, 20)\ncairo_move_to(cr, 0, 30)\ncairo_show_text(cr, 'H')")
    #expect(scaled.ink(0..<100, 62..<80) == 0 && scaled.ink(0..<100, 31..<60) > 0 && scaled.ink(0..<10, 0..<80) == 0)
}

@Test func clipRestrictsEveryDrawingOperation() throws {
    let theme = try run("""
      cairo_rectangle(cr, 20, 20, 40, 30)
      cairo_clip(cr)
      cairo_rectangle(cr, 0, 0, 100, 80)
      cairo_fill(cr)
    """)
    #expect(theme.alpha(40, 35) == 255 && theme.alpha(20, 20) == 255 && theme.alpha(59, 49) == 255)
    #expect(theme.alpha(10, 35) == 0 && theme.alpha(70, 35) == 0 && theme.alpha(40, 10) == 0 && theme.alpha(40, 60) == 0)
    let all = try run("""
      cairo_rectangle(cr, 20, 20, 40, 30)
      cairo_clip(cr)
      cairo_paint(cr)
      cairo_set_source_rgb(cr, 0, 0, 1)
      cairo_set_line_width(cr, 10)
      cairo_move_to(cr, 0, 35)
      cairo_line_to(cr, 100, 35)
      cairo_stroke(cr)
      local p = cairo_pattern_create_linear(0, 0, 100, 0)
      cairo_pattern_add_color_stop_rgba(p, 0, 1, 0, 0, 1)
      cairo_pattern_add_color_stop_rgba(p, 1, 0, 1, 0, 1)
      cairo_set_source(cr, p)
      cairo_move_to(cr, 0, 60)
      cairo_line_to(cr, 100, 60)
      cairo_stroke(cr)
      cairo_set_font_size(cr, 60)
      cairo_move_to(cr, 0, 70)
      cairo_show_text(cr, 'MM')
    """)
    #expect(all.ink(0..<20, 0..<80) == 0 && all.ink(60..<100, 0..<80) == 0)
    #expect(all.ink(0..<100, 0..<20) == 0 && all.ink(0..<100, 50..<80) == 0)
    #expect(all.alpha(40, 35) == 255)
}

@Test func clipClearsThePathUnlessPreserved() throws {
    let cleared = try run("""
      cairo_rectangle(cr, 20, 20, 40, 30)
      cairo_clip(cr)
      cairo_fill(cr)  -- the path was consumed by cairo_clip
    """)
    #expect(cleared.ink() == 0)
    let preserved = try run("""
      cairo_rectangle(cr, 20, 20, 40, 30)
      cairo_clip_preserve(cr)
      cairo_fill(cr)
    """)
    #expect(preserved.alpha(30, 30) == 255 && preserved.ink() == 255 * 40 * 30)
    // Clips intersect; an empty path clips everything.
    let nested = try run("""
      cairo_rectangle(cr, 0, 0, 50, 50)
      cairo_clip(cr)
      cairo_rectangle(cr, 25, 25, 50, 50)
      cairo_clip(cr)
      cairo_paint(cr)
    """)
    #expect(nested.ink() == 255 * 25 * 25 && nested.alpha(30, 30) == 255 && nested.alpha(10, 10) == 0 && nested.alpha(60, 60) == 0)
    let empty = try run("cairo_clip(cr)\ncairo_paint(cr)")
    #expect(empty.ink() == 0)
    let lone = try run("cairo_move_to(cr, 5, 5)\ncairo_clip(cr)\ncairo_paint(cr)")
    #expect(lone.ink() == 0)
    let line = try run("cairo_move_to(cr, 5, 5)\ncairo_line_to(cr, 90, 70)\ncairo_clip(cr)\ncairo_paint(cr)")
    #expect(line.ink() < 400)
    let evenOdd = try run("""
      cairo_set_fill_rule(cr, CAIRO_FILL_RULE_EVEN_ODD)
      cairo_rectangle(cr, 0, 0, 80, 80)
      cairo_rectangle(cr, 20, 20, 40, 40)
      cairo_clip(cr)
      cairo_set_fill_rule(cr, CAIRO_FILL_RULE_WINDING)
      cairo_paint(cr)
    """)
    #expect(evenOdd.alpha(10, 10) == 255 && evenOdd.alpha(40, 40) == 0)
}

@Test func saveRestoreAndResetClip() throws {
    let restored = try run("""
      cairo_save(cr)
      cairo_rectangle(cr, 20, 20, 20, 20)
      cairo_clip(cr)
      cairo_paint(cr)
      cairo_restore(cr)
      cairo_set_source_rgb(cr, 0, 0, 1)
      cairo_rectangle(cr, 60, 20, 20, 20)
      cairo_fill(cr)  -- unclipped again after the restore
    """)
    #expect(restored.alpha(30, 30) == 255 && restored.alpha(70, 30) == 255)
    let reset = try run("""
      cairo_rectangle(cr, 20, 20, 20, 20)
      cairo_clip(cr)
      cairo_reset_clip(cr)
      cairo_paint(cr)
    """)
    #expect(reset.ink() == 255 * 100 * 80)
    // reset_clip only drops the current state's clip; the saved one returns on restore.
    let layered = try run("""
      cairo_rectangle(cr, 0, 0, 50, 80)
      cairo_clip(cr)
      cairo_save(cr)
      cairo_reset_clip(cr)
      cairo_rectangle(cr, 0, 0, 100, 10)
      cairo_fill(cr)
      cairo_restore(cr)
      cairo_rectangle(cr, 0, 70, 100, 10)
      cairo_fill(cr)
    """)
    #expect(layered.alpha(80, 5) == 255 && layered.alpha(80, 75) == 0 && layered.alpha(20, 75) == 255)
    // Clips survive a many-level save chain, and a clip made inside a save is gone after restore.
    let deep = try run("""
      for i = 1, 15 do cairo_save(cr) end
      cairo_rectangle(cr, 0, 0, 10, 10)
      cairo_clip(cr)
      for i = 1, 15 do cairo_restore(cr) end
      cairo_paint(cr)
    """)
    #expect(deep.ink() == 255 * 100 * 80)
}

@Test func clipChainsAreBoundedAndReleased() throws {
    let tooDeep = try Theme(textPrelude + """
      for i = 1, 100 do cairo_rectangle(cr, 0, 0, 100, 80); cairo_clip(cr) end
    end
    """)
    #expect(tooDeep.draw() != 0 && tooDeep.error.contains("too many nested clips"))
    // Contexts that are abandoned or destroyed with clips (and saved clips) must not leak or crash.
    let churn = try Theme(prelude + """
      for i = 1, 300 do
        local c = cairo_create(cairo_xlib_surface_create())
        cairo_rectangle(c, 0, 0, 50, 50); cairo_clip(c)
        cairo_save(c); cairo_rectangle(c, 0, 0, 20, 20); cairo_clip(c); cairo_save(c)
        if i % 2 == 0 then cairo_destroy(c) end
      end
      collectgarbage()
    end
    """)
    #expect(churn.draw() == 0, "\(churn.error)")
    // A persistent cairo_t that clips each frame inside save/restore never accumulates.
    let persistent = try Theme(prelude.replacingOccurrences(of: "local cr", with: "cr") + """
      for frame = 1, 500 do
        cairo_save(cr)
        cairo_rectangle(cr, 0, 0, 50, 50)
        cairo_clip(cr)
        cairo_restore(cr)
      end
      cairo_paint(cr)
    end
    """)
    #expect(persistent.draw() == 0, "\(persistent.error)")
    #expect(persistent.alpha(90, 70) == 255)
}

@Test func dashesAlternateAlongTheLine() throws {
    let theme = try run("""
      cairo_set_line_width(cr, 4)
      cairo_set_dash(cr, {10, 10}, 2, 0)
      cairo_move_to(cr, 0, 40)
      cairo_line_to(cr, 100, 40)
      cairo_stroke(cr)
    """)
    #expect(theme.alpha(5, 40) == 255 && theme.alpha(15, 40) == 0 && theme.alpha(25, 40) == 255 && theme.alpha(35, 40) == 0)
    let offset = try run("""
      cairo_set_line_width(cr, 4)
      cairo_set_dash(cr, {10, 10}, 2, 10)
      cairo_move_to(cr, 0, 40)
      cairo_line_to(cr, 100, 40)
      cairo_stroke(cr)
    """)
    #expect(offset.alpha(5, 40) == 0 && offset.alpha(15, 40) == 255)
    // Dashes follow the CTM, survive save/restore, and count 0 turns them off.
    let scaled = try run("""
      cairo_scale(cr, 2, 2)
      cairo_set_line_width(cr, 2)
      cairo_save(cr)
      cairo_set_dash(cr, {5}, 1, 0)
      cairo_restore(cr)
      cairo_set_dash(cr, {5, 5}, 2, 0)
      cairo_move_to(cr, 0, 20)
      cairo_line_to(cr, 50, 20)
      cairo_stroke(cr)
      cairo_set_dash(cr, {}, 0, 0)
      cairo_move_to(cr, 0, 30)
      cairo_line_to(cr, 50, 30)
      cairo_stroke(cr)
    """)
    #expect(scaled.alpha(5, 40) == 255 && scaled.alpha(15, 40) == 0 && scaled.alpha(25, 40) == 255)
    #expect(scaled.alpha(15, 60) == 255)
    // Dashed gradient strokes use the same dashes.
    let gradient = try run("""
      local p = cairo_pattern_create_linear(0, 0, 100, 0)
      cairo_pattern_add_color_stop_rgba(p, 0, 1, 0, 0, 1)
      cairo_pattern_add_color_stop_rgba(p, 1, 0, 0, 1, 1)
      cairo_set_source(cr, p)
      cairo_set_line_width(cr, 4)
      cairo_set_dash(cr, {10, 10}, 2, 0)
      cairo_move_to(cr, 0, 40)
      cairo_line_to(cr, 100, 40)
      cairo_stroke(cr)
    """)
    #expect(gradient.alpha(5, 40) == 255 && gradient.alpha(15, 40) == 0)
}

@Test func operatorsClearSourceAndAdd() throws {
    let cleared = try run("""
      cairo_paint(cr)
      cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR)
      cairo_rectangle(cr, 20, 20, 30, 30)
      cairo_fill(cr)
      cairo_set_operator(cr, CAIRO_OPERATOR_OVER)
      cairo_set_source_rgba(cr, 0, 0, 1, 0.5)
      cairo_rectangle(cr, 60, 20, 10, 10)
      cairo_fill(cr)
    """)
    #expect(cleared.alpha(30, 30) == 0 && cleared.alpha(10, 10) == 255 && cleared.alpha(65, 25) == 255)
    let source = try run("""
      cairo_paint(cr)
      cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE)
      cairo_set_source_rgba(cr, 0, 0, 1, 0.5)
      cairo_rectangle(cr, 20, 20, 30, 30)
      cairo_fill(cr)
      cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR)
      cairo_set_font_size(cr, 30)
      cairo_move_to(cr, 60, 60)
      cairo_show_text(cr, 'I')
    """)
    #expect(abs(Int(source.alpha(30, 30)) - 128) <= 1 && source.alpha(10, 10) == 255)
    let add = try run("""
      cairo_set_source_rgba(cr, 0, 0, 0, 0.25)
      cairo_set_operator(cr, CAIRO_OPERATOR_ADD)
      for i = 1, 2 do cairo_rectangle(cr, 20, 20, 30, 30); cairo_fill(cr) end
    """)
    #expect(abs(Int(add.alpha(30, 30)) - 128) <= 2)
    let dest = try run("""
      cairo_set_operator(cr, CAIRO_OPERATOR_DEST)
      cairo_paint(cr)
      cairo_rectangle(cr, 20, 20, 30, 30)
      cairo_fill(cr)
      cairo_set_font_size(cr, 30)
      cairo_move_to(cr, 60, 60)
      cairo_show_text(cr, 'I')
    """)
    #expect(dest.ink() == 0)
    // Operators are part of the saved state; the others are refused by name.
    let saved = try run("""
      cairo_save(cr)
      cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR)
      cairo_restore(cr)
      cairo_paint(cr)
    """)
    #expect(saved.ink() == 255 * 100 * 80)
    let unsupported = try Theme(textPrelude + "  cairo_set_operator(cr, 11)\nend")
    #expect(unsupported.draw() != 0 && unsupported.error.contains("operator 11 is not supported"))
    let named = try Theme(textPrelude + "  cairo_set_operator(cr, CAIRO_OPERATOR_XOR)\nend")
    #expect(named.draw() != 0 && named.error.contains("unsupported cairo API 'CAIRO_OPERATOR_XOR'"))
}

@Test func hostileTextInputsRaiseLuaErrorsNotCrashes() throws {
    let cases: [(String, String)] = [
        ("cairo_show_text(cr, string.rep('A', 5000))", "longer than 4096"),
        ("cairo_text_path(cr, string.rep('A', 4097))", "longer than 4096"),
        ("local e = cairo_text_extents_t:create(); cairo_text_extents(cr, string.rep('A', 100000), e)", "longer than 4096"),
        ("cairo_show_text(cr, '\\xff\\xfe')", "not valid UTF-8"),
        ("cairo_show_text(cr, '\\xc0\\x80')", "not valid UTF-8"),
        ("cairo_show_text(cr, '\\xed\\xa0\\x80')", "not valid UTF-8"),
        ("cairo_show_text(cr, '\\xf4\\x90\\x80\\x80')", "not valid UTF-8"),
        ("cairo_show_text(cr, 'abc\\xe4\\xb8')", "not valid UTF-8"),
        ("cairo_set_font_size(cr, 0/0)", "font size"),
        ("cairo_set_font_size(cr, math.huge)", "font size"),
        ("cairo_set_font_size(cr, 0)", "font size"),
        ("cairo_set_font_size(cr, -5)", "font size"),
        ("cairo_set_font_size(cr, 1e5)", "font size"),
        ("cairo_scale(cr, 1e300, 1e300)", "transformation"),
        ("cairo_scale(cr, 1e150, 1e150); cairo_scale(cr, 1e150, 1e150)", "transformation"),
        ("cairo_translate(cr, 0/0, 0)", "transformation"),
        ("cairo_translate(cr, 1e300, 0)", "transformation"),
        ("cairo_rotate(cr, math.huge)", "transformation"),
        ("cairo_scale(cr, 1e-200, 1e-200)", "transformation"),
        ("cairo_select_font_face(cr, string.rep('x', 300), 0, 0)", "too long"),
        ("cairo_select_font_face(cr, 'x', 3, 0)", "invalid enum"),
        ("cairo_select_font_face(cr, {}, 0, 0)", "string expected"),
        ("cairo_show_text(cr, {})", "string expected"),
        ("cairo_text_extents(cr, 'x', 5)", "table expected"),
        ("cairo_font_extents(cr, nil)", "table expected"),
        ("cairo_set_dash(cr, {-1, 2}, 2, 0)", "dash lengths"),
        ("cairo_set_dash(cr, {0, 0}, 2, 0)", "all be zero"),
        ("cairo_set_dash(cr, {1, 'x'}, 2, 0)", "dash lengths"),
        ("cairo_set_dash(cr, {1, 2}, 5, 0)", "dash lengths"),
        ("cairo_set_dash(cr, {1, 2}, 33, 0)", "number of dashes"),
        ("cairo_set_dash(cr, {1, 2}, 2, 0/0)", "dash offset"),
        ("cairo_set_dash(cr, {math.huge}, 1, 0)", "dash lengths"),
        ("cairo_set_dash(cr, {0.0001}, 1, 0); cairo_move_to(cr, 0, 0); cairo_line_to(cr, 1e9, 0); cairo_stroke(cr)", "too fine"),
        ("cairo_set_operator(cr, 99)", "invalid enum"),
        ("cairo_set_operator(cr, 'a')", "number expected"),
    ]
    for (body, expected) in cases {
        let theme = try Theme(textPrelude + body + "\nend")
        #expect(theme.draw() != 0 && theme.error.contains(expected), "\(body): \(theme.error)")
    }
    // The theme keeps working after a failed call (no CF object or CTM left in a bad state).
    let recovered = try Theme(textPrelude + """
      calls = (calls or 0) + 1
      if calls == 1 then cairo_scale(cr, 1e300, 1e300) end
      cairo_set_font_size(cr, 20); cairo_move_to(cr, 10, 40); cairo_show_text(cr, 'ok')
    end
    """)
    #expect(recovered.draw() != 0)
    #expect(recovered.draw() == 0 && recovered.ink() > 0, "\(recovered.error)")
    // Drawing text outside a draw hook is refused, but measuring is not drawing.
    let early = try Theme("cr = cairo_create(cairo_xlib_surface_create())\ncairo_show_text(cr, 'x')")
    #expect(early.error.contains("only possible while a Conky draw hook runs"))
}

@Test func textStateIsPerContextSavedAndBounded() throws {
    // Font settings are saved and restored; many distinct sizes cycle the font cache without changing results.
    _ = try run("""
      cairo_set_font_size(cr, 21)
      local a = cairo_text_extents_t:create()
      cairo_text_extents(cr, 'Cache', a)
      cairo_save(cr)
      cairo_select_font_face(cr, 'Courier', CAIRO_FONT_SLANT_ITALIC, CAIRO_FONT_WEIGHT_BOLD)
      cairo_set_font_size(cr, 7)
      cairo_restore(cr)
      for size = 5, 200 do
        cairo_set_font_size(cr, size)
        local e = cairo_text_extents_t:create()
        cairo_text_extents(cr, 'Cache', e)
        assert(e.x_advance > 0)
      end
      cairo_set_font_size(cr, 21)
      local b = cairo_text_extents_t:create()
      cairo_text_extents(cr, 'Cache', b)
      assert(a.x_advance == b.x_advance and a.width == b.width, 'same font after eviction')
    """)
    // A persistent cairo_t that only shows text does not grow its path; text_path alone is capped.
    let persistent = try Theme(prelude.replacingOccurrences(of: "local cr", with: "cr") + """
      cairo_set_font_size(cr, 12)
      for i = 1, 3000 do cairo_move_to(cr, 5, 20); cairo_show_text(cr, 'tick') end
      for i = 1, 3000 do cairo_show_text(cr, ' ') end
    end
    """, budget: 5000)
    #expect(persistent.draw() == 0, "\(persistent.error)")
    let capped = try Theme(textPrelude + """
      cairo_set_font_size(cr, 100)
      for i = 1, 100000 do cairo_text_path(cr, string.rep('@&%', 100)) end
    end
    """, budget: 5000)
    #expect(capped.draw() != 0 && capped.error.contains("too many path elements"), "\(capped.error)")
    // Fresh paths reset the budget.
    let reset = try Theme(textPrelude + """
      cairo_set_font_size(cr, 30)
      for i = 1, 40 do cairo_text_path(cr, string.rep('@&%', 100)); cairo_new_path(cr) end
    end
    """, budget: 5000)
    #expect(reset.draw() == 0, "\(reset.error)")
}

@Test func tolauaStyleExtentsWork() throws {
    // Written the way Conky scripts use the tolua++ bindings.
    _ = try run("""
      local extents = cairo_text_extents_t:create()
      tolua.takeownership(extents)
      cairo_set_font_size(cr, 14)
      cairo_text_extents(cr, 'centered', extents)
      local x = 50 - (extents.width / 2 + extents.x_bearing)
      local y = 40 - (extents.height / 2 + extents.y_bearing)
      cairo_move_to(cr, x, y)
      cairo_show_text(cr, 'centered')
      local fe = cairo_font_extents_t:create()
      tolua.takeownership(fe)
      cairo_font_extents(cr, fe)
      assert(type(fe.height) == 'number' and fe.max_y_advance == 0)
      assert(type(extents) == 'table' and getmetatable(extents) == nil)
    """)
    let centered = try run("""
      local e = cairo_text_extents_t:create()
      cairo_set_font_size(cr, 14)
      cairo_text_extents(cr, 'centered', e)
      cairo_move_to(cr, 50 - (e.width / 2 + e.x_bearing), 40 - (e.height / 2 + e.y_bearing))
      cairo_show_text(cr, 'centered')
    """)
    // The ink is centred on (50, 40) to within a pixel or two.
    #expect(abs(centered.centroid(0..<80) - 50) < 3)
    let rows = (0..<80).filter { centered.ink(0..<100, $0..<($0 + 1)) > 0 }
    #expect(abs(Double(rows.first! + rows.last!) / 2 - 40) < 2)
}

@Test func textLoopsHitTheTimeBudget() throws {
    for call in ["cairo_show_text(cr, text)", "cairo_text_path(cr, text); cairo_new_path(cr)",
                 "cairo_text_extents(cr, text, e)", "pcall(cairo_show_text, cr, text)"] {
        let theme = try Theme(textPrelude + """
          local text, e = string.rep('Hello wide world ', 240), cairo_text_extents_t:create()
          cairo_set_font_size(cr, 12)
          while true do \(call) end
        end
        """, budget: 50)
        let start = Date()
        #expect(theme.draw() != 0 && theme.error.contains("time budget"), "\(call): \(theme.error)")
        #expect(Date().timeIntervalSince(start) < 1, "\(call)")
    }
}
