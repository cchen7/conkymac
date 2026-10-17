-- ConkyMac test fixture (our own code). Text in several faces and sizes, centred and clipped text,
-- gradient-filled and outlined text, dashed lines and the CLEAR operator.
require 'cairo'

local function face(cr, family, slant, weight, size)
    cairo_select_font_face(cr, family, slant, weight)
    cairo_set_font_size(cr, size)
end

local function text_at(cr, x, y, text)
    cairo_move_to(cr, x, y)
    cairo_show_text(cr, text)
end

function conky_text()
    if conky_window == nil then return end
    local w, h = conky_window.width, conky_window.height
    local cs = cairo_xlib_surface_create(conky_window.display, conky_window.drawable, conky_window.visual, w, h)
    local cr = cairo_create(cs)

    cairo_set_source_rgb(cr, 0.10, 0.12, 0.16)
    cairo_paint(cr)

    -- Sizes and faces; y is the baseline.
    cairo_set_source_rgb(cr, 1, 1, 1)
    face(cr, 'sans', CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL, 12)
    text_at(cr, 12, 22, 'sans 12  The quick brown fox 0123456789')
    face(cr, 'sans', CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD, 18)
    text_at(cr, 12, 46, 'sans bold 18')
    face(cr, 'serif', CAIRO_FONT_SLANT_ITALIC, CAIRO_FONT_WEIGHT_NORMAL, 20)
    text_at(cr, 160, 46, 'serif italic 20')
    face(cr, 'monospace', CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL, 12)
    text_at(cr, 12, 68, 'monospace 12  { }[] ~ 中文')
    face(cr, 'Helvetica', CAIRO_FONT_SLANT_OBLIQUE, CAIRO_FONT_WEIGHT_NORMAL, 14)
    text_at(cr, 12, 90, 'oblique skew')

    -- Centred with text_extents, over a dashed frame.
    local label = 'Centered'
    local e = cairo_text_extents_t:create()
    tolua.takeownership(e)
    face(cr, 'sans', CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD, 22)
    cairo_text_extents(cr, label, e)
    cairo_set_source_rgb(cr, 1, 0.8, 0.3)
    text_at(cr, 100 - (e.width / 2 + e.x_bearing), 140 - (e.height / 2 + e.y_bearing), label)
    cairo_set_source_rgba(cr, 1, 1, 1, 0.8)
    cairo_set_line_width(cr, 1.5)
    cairo_set_dash(cr, {6, 4}, 2, 0)
    cairo_rectangle(cr, 100 - e.width / 2 - 8, 140 - e.height / 2 - 8, e.width + 16, e.height + 16)
    cairo_stroke(cr)
    cairo_set_dash(cr, {}, 0, 0)

    -- Clipped text and a clipped gradient; the clip is undone by restore.
    cairo_save(cr)
    cairo_rectangle(cr, 200, 110, 140, 36)
    cairo_clip(cr)
    cairo_set_source_rgb(cr, 0.2, 0.5, 0.9)
    cairo_paint(cr)
    cairo_set_source_rgb(cr, 1, 1, 1)
    face(cr, 'sans', CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD, 40)
    text_at(cr, 206, 144, 'Clipped Text')
    cairo_restore(cr)
    cairo_set_source_rgb(cr, 0.7, 0.7, 0.7)
    face(cr, 'sans', CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL, 10)
    text_at(cr, 200, 160, 'clip ends here (unclipped)')

    -- Gradient-filled and outlined text through text_path.
    local gradient = cairo_pattern_create_linear(12, 0, 252, 0)
    cairo_pattern_add_color_stop_rgb(gradient, 0, 1, 0.3, 0.3)
    cairo_pattern_add_color_stop_rgb(gradient, 0.5, 1, 0.9, 0.2)
    cairo_pattern_add_color_stop_rgb(gradient, 1, 0.3, 0.8, 1)
    face(cr, 'sans', CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD, 40)
    cairo_move_to(cr, 12, 214)
    cairo_text_path(cr, 'Gradient')
    cairo_set_source(cr, gradient)
    cairo_fill_preserve(cr)
    cairo_set_source_rgb(cr, 0, 0, 0)
    cairo_set_line_width(cr, 1)
    cairo_stroke(cr)
    cairo_pattern_destroy(gradient)

    -- Rotated text and a clock-style text on a scaled axis.
    cairo_save(cr)
    cairo_translate(cr, 280, 230)
    cairo_rotate(cr, -math.pi / 6)
    cairo_set_source_rgb(cr, 0.6, 1, 0.6)
    face(cr, 'sans', CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL, 16)
    text_at(cr, 0, 0, 'rotated')
    cairo_restore(cr)

    -- Dashed lines: round caps, a dash offset, and an odd-length pattern.
    cairo_set_source_rgb(cr, 1, 1, 1)
    cairo_set_line_width(cr, 3)
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
    cairo_set_dash(cr, {0.1, 8}, 2, 0)
    cairo_move_to(cr, 12, 250); cairo_line_to(cr, 180, 250); cairo_stroke(cr)
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_BUTT)
    cairo_set_dash(cr, {12, 6}, 2, 9)
    cairo_move_to(cr, 12, 264); cairo_line_to(cr, 180, 264); cairo_stroke(cr)
    cairo_set_dash(cr, {10, 4, 2}, 3, 0)
    cairo_move_to(cr, 12, 278); cairo_line_to(cr, 180, 278); cairo_stroke(cr)
    cairo_set_dash(cr, {}, 0, 0)

    -- CLEAR cuts a hole through everything drawn so far, text included.
    cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR)
    face(cr, 'sans', CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD, 30)
    text_at(cr, 196, 280, 'HOLE')
    cairo_set_operator(cr, CAIRO_OPERATOR_OVER)

    cairo_destroy(cr)
    cairo_surface_destroy(cs)
end
