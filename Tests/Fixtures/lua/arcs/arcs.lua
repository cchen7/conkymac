-- ConkyMac test fixture (our own code). Draws metric rings and shape samples.
require 'cairo'

local function value(template)
    return tonumber(conky_parse(template)) or 0
end

local function ring(cr, x, y, radius, fraction, r, g, b)
    local start = -math.pi / 2
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_BUTT)
    cairo_set_line_width(cr, 10)
    cairo_set_source_rgba(cr, 1, 1, 1, 0.15)
    cairo_arc(cr, x, y, radius, 0, 2 * math.pi)
    cairo_stroke(cr)
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
    cairo_set_source_rgba(cr, r, g, b, 1)
    cairo_arc(cr, x, y, radius, start, start + fraction * 2 * math.pi)
    cairo_stroke(cr)
end

function conky_arcs()
    if conky_window == nil then return end
    local w, h = conky_window.width, conky_window.height
    local cs = cairo_xlib_surface_create(conky_window.display, conky_window.drawable, conky_window.visual, w, h)
    local cr = cairo_create(cs)

    -- Panel: linear gradient fill, then a border on the same path.
    local panel = cairo_pattern_create_linear(0, 0, 0, h)
    cairo_pattern_add_color_stop_rgba(panel, 0, 0.20, 0.24, 0.32, 0.9)
    cairo_pattern_add_color_stop_rgb(panel, 1, 0.05, 0.06, 0.09)
    cairo_move_to(cr, 16, 4)
    cairo_line_to(cr, w - 16, 4)
    cairo_curve_to(cr, w - 4, 4, w - 4, 4, w - 4, 16)
    cairo_line_to(cr, w - 4, h - 16)
    cairo_curve_to(cr, w - 4, h - 4, w - 4, h - 4, w - 16, h - 4)
    cairo_line_to(cr, 16, h - 4)
    cairo_curve_to(cr, 4, h - 4, 4, h - 4, 4, h - 16)
    cairo_line_to(cr, 4, 16)
    cairo_curve_to(cr, 4, 4, 4, 4, 16, 4)
    cairo_close_path(cr)
    cairo_set_source(cr, panel)
    cairo_fill_preserve(cr)
    cairo_set_source_rgba(cr, 0.6, 0.7, 0.9, 0.8)
    cairo_set_line_width(cr, 2)
    cairo_stroke_preserve(cr)
    cairo_new_path(cr)
    cairo_pattern_destroy(panel)

    -- Rings: cpu (red), memory (green), storage (blue), battery (amber); start at 12 o'clock, clockwise.
    ring(cr, 60, 60, 36, value('${cpu}') / 100, 0.95, 0.35, 0.35)
    ring(cr, 140, 60, 36, value('${memperc}') / 100, 0.35, 0.85, 0.45)
    ring(cr, 220, 60, 36, value('${fs_used_perc /}') / 100, 0.35, 0.55, 0.95)
    ring(cr, 300, 60, 36, value('${battery_percent}') / 100, 0.95, 0.75, 0.25)

    -- Radial gradient disc with an even-odd hole.
    local glow = cairo_pattern_create_radial(60, 170, 4, 60, 170, 40)
    cairo_pattern_add_color_stop_rgba(glow, 0, 1, 1, 1, 1)
    cairo_pattern_add_color_stop_rgba(glow, 1, 0.2, 0.4, 1, 0.2)
    cairo_set_fill_rule(cr, CAIRO_FILL_RULE_EVEN_ODD)
    cairo_arc(cr, 60, 170, 40, 0, 2 * math.pi)
    cairo_new_sub_path(cr)
    cairo_arc(cr, 60, 170, 12, 0, 2 * math.pi)
    cairo_set_source(cr, glow)
    cairo_pattern_destroy(glow)
    cairo_fill(cr)
    cairo_set_fill_rule(cr, CAIRO_FILL_RULE_WINDING)

    -- Clock-like ticks with save/translate/rotate/restore; arc_negative traces the top-right quarter counterclockwise.
    cairo_save(cr)
    cairo_translate(cr, 160, 170)
    cairo_set_source_rgba(cr, 0.9, 0.9, 0.9, 0.9)
    cairo_set_line_width(cr, 3)
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_SQUARE)
    for i = 0, 11 do
        cairo_save(cr)
        cairo_rotate(cr, i * math.pi / 6)
        cairo_move_to(cr, 0, -36)
        cairo_rel_line_to(cr, 0, i % 3 == 0 and 10 or 5)
        cairo_stroke(cr)
        cairo_restore(cr)
    end
    cairo_set_source_rgba(cr, 0.95, 0.35, 0.35, 1)
    cairo_arc_negative(cr, 0, 0, 24, 0, -math.pi / 2)
    cairo_stroke(cr)
    cairo_restore(cr)

    -- Scaled rectangle stroked with a gradient, and a joined polyline.
    cairo_save(cr)
    cairo_translate(cr, 230, 140)
    cairo_scale(cr, 2, 1)
    local bar = cairo_pattern_create_linear(0, 0, 50, 0)
    cairo_pattern_add_color_stop_rgb(bar, 0, 1, 0.3, 0.3)
    cairo_pattern_add_color_stop_rgb(bar, 1, 0.3, 0.3, 1)
    cairo_rectangle(cr, 0, 0, 50, 20)
    cairo_set_source(cr, bar)
    cairo_set_line_width(cr, 4)
    cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
    cairo_stroke(cr)
    cairo_restore(cr)
    cairo_set_source_rgb(cr, 0.35, 0.85, 0.45)
    cairo_set_line_width(cr, 5)
    cairo_set_line_join(cr, CAIRO_LINE_JOIN_MITER)
    cairo_move_to(cr, 230, 230)
    cairo_line_to(cr, 260, 190)
    cairo_line_to(cr, 290, 230)
    cairo_line_to(cr, 320, 190)
    cairo_stroke(cr)

    cairo_destroy(cr)
    cairo_destroy(cr)
    cairo_surface_destroy(cs)
end
