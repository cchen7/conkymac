#include "Internal.h"
#include <math.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

// A cairo API subset on CoreGraphics. Paths are kept per cairo_t in frame user space
// (Conky pixels, y-down); the cairo CTM is applied while building them, as cairo does.

#define SURFACE "cairo_surface_t"
#define CONTEXT "cairo_t"
#define PATTERN "cairo_pattern_t"
#define MAX_DEPTH 16
#define MAX_STOPS 256

typedef struct { bool destroyed; } Surface;
typedef struct { double offset, r, g, b, a; } Stop;

typedef struct {
    bool destroyed, radial;
    double x0, y0, r0, x1, y1, r1;
    int count, capacity;
    Stop *_Nullable stops;
    CGGradientRef _Nullable gradient;
} Pattern;

typedef struct {
    CGAffineTransform ctm, source_ctm;
    double r, g, b, a, line_width, miter_limit;
    Pattern *_Nullable pattern;  // Kept alive by the context's uservalue table.
    int cap, join, fill_rule;
} GState;

typedef struct {
    bool destroyed, has_point;
    CGMutablePathRef _Nullable path;
    int depth;
    GState states[MAX_DEPTH];
} Context;

static int fail(lua_State *L, const char *message) {
    lua_Debug ar;
    const char *name = NULL;
    if (lua_getstack(L, 0, &ar) && lua_getinfo(L, "n", &ar)) name = ar.name;
    return luaL_error(L, "%s: %s", name ? name : "cairo", message);
}

static double clamp(double value) { return value < 0 ? 0 : value > 1 ? 1 : value; }

static Context *check_context(lua_State *L) {
    Context *c = luaL_checkudata(L, 1, CONTEXT);
    if (c->destroyed) luaL_argerror(L, 1, "cairo_t used after cairo_destroy");
    return c;
}

static Pattern *check_pattern(lua_State *L, int index) {
    Pattern *p = luaL_checkudata(L, index, PATTERN);
    if (p->destroyed) luaL_argerror(L, index, "pattern used after cairo_pattern_destroy");
    return p;
}

static GState *state(Context *c) { return &c->states[c->depth]; }

static CGContextRef target(lua_State *L) {
    CGContextRef cg = conky_self(L)->context;
    if (!cg) fail(L, "drawing is only possible while a Conky draw hook runs");
    return cg;
}

// MARK: Surfaces and contexts

static int surface_create(lua_State *L) {
    Surface *s = lua_newuserdatauv(L, sizeof *s, 0);
    s->destroyed = false;
    luaL_setmetatable(L, SURFACE);
    return 1;
}

static int surface_destroy(lua_State *L) {
    ((Surface *)luaL_checkudata(L, 1, SURFACE))->destroyed = true;
    return 0;
}

static int create(lua_State *L) {
    Surface *s = luaL_checkudata(L, 1, SURFACE);
    if (s->destroyed) luaL_argerror(L, 1, "surface used after cairo_surface_destroy");
    Context *c = lua_newuserdatauv(L, sizeof *c, 1);
    memset(c, 0, sizeof *c);
    luaL_setmetatable(L, CONTEXT);
    lua_newtable(L);
    lua_setiuservalue(L, -2, 1);
    c->path = CGPathCreateMutable();
    if (!c->path) fail(L, "out of memory");
    c->states[0] = (GState){.ctm = CGAffineTransformIdentity, .source_ctm = CGAffineTransformIdentity,
                            .a = 1, .line_width = 2, .miter_limit = 10};
    return 1;
}

static void release_context(Context *c) {
    CGPathRelease(c->path);
    c->path = NULL;
}

static int context_gc(lua_State *L) {
    release_context(luaL_checkudata(L, 1, CONTEXT));
    return 0;
}

static int destroy(lua_State *L) {
    Context *c = luaL_checkudata(L, 1, CONTEXT);
    if (c->destroyed) return 0;
    c->destroyed = true;
    release_context(c);
    lua_pushnil(L);
    lua_setiuservalue(L, 1, 1);
    return 0;
}

static int save(lua_State *L) {
    Context *c = check_context(L);
    if (c->depth + 1 >= MAX_DEPTH) return fail(L, "cairo_save nested too deeply");
    lua_getiuservalue(L, 1, 1);
    lua_rawgeti(L, -1, c->depth + 1);
    lua_rawseti(L, -2, c->depth + 2);
    c->states[c->depth + 1] = c->states[c->depth];
    c->depth++;
    return 0;
}

static int restore(lua_State *L) {
    Context *c = check_context(L);
    if (c->depth == 0) return fail(L, "cairo_restore without matching cairo_save");
    c->depth--;
    lua_getiuservalue(L, 1, 1);
    lua_pushnil(L);
    lua_rawseti(L, -2, c->depth + 2);
    return 0;
}

// MARK: Paths

static void move_to(Context *c, double x, double y) {
    CGPathMoveToPoint(c->path, &state(c)->ctm, x, y);
    c->has_point = true;
}

static void line_to(Context *c, double x, double y) {
    if (!c->has_point) move_to(c, x, y);
    else CGPathAddLineToPoint(c->path, &state(c)->ctm, x, y);
}

static int l_move_to(lua_State *L) {
    Context *c = check_context(L);
    move_to(c, luaL_checknumber(L, 2), luaL_checknumber(L, 3));
    return 0;
}

static int l_line_to(lua_State *L) {
    Context *c = check_context(L);
    line_to(c, luaL_checknumber(L, 2), luaL_checknumber(L, 3));
    return 0;
}

static int relative(lua_State *L, bool line) {
    Context *c = check_context(L);
    double dx = luaL_checknumber(L, 2), dy = luaL_checknumber(L, 3);
    if (!c->has_point) return fail(L, "no current point");
    CGPoint point = CGPathGetCurrentPoint(c->path);
    CGSize delta = CGSizeApplyAffineTransform(CGSizeMake(dx, dy), state(c)->ctm);
    if (line) CGPathAddLineToPoint(c->path, NULL, point.x + delta.width, point.y + delta.height);
    else CGPathMoveToPoint(c->path, NULL, point.x + delta.width, point.y + delta.height);
    return 0;
}
static int rel_move_to(lua_State *L) { return relative(L, false); }
static int rel_line_to(lua_State *L) { return relative(L, true); }

static int curve_to(lua_State *L) {
    Context *c = check_context(L);
    double v[6];
    for (int index = 0; index < 6; index++) v[index] = luaL_checknumber(L, index + 2);
    if (!c->has_point) move_to(c, v[0], v[1]);
    CGPathAddCurveToPoint(c->path, &state(c)->ctm, v[0], v[1], v[2], v[3], v[4], v[5]);
    return 0;
}

static int arc(lua_State *L, bool negative) {
    Context *c = check_context(L);
    double xc = luaL_checknumber(L, 2), yc = luaL_checknumber(L, 3), radius = luaL_checknumber(L, 4);
    double a1 = luaL_checknumber(L, 5), a2 = luaL_checknumber(L, 6);
    if (!isfinite(xc) || !isfinite(yc) || !isfinite(radius) || !isfinite(a1) || !isfinite(a2))
        return fail(L, "non-finite argument");
    // cairo's angle normalisation: at most one full turn, in the requested direction.
    if (!negative && a2 < a1) { a2 = fmod(a2 - a1, 2 * M_PI); if (a2 < 0) a2 += 2 * M_PI; a2 += a1; }
    if (negative && a2 > a1) { a2 = fmod(a2 - a1, 2 * M_PI); if (a2 > 0) a2 -= 2 * M_PI; a2 += a1; }
    if (fabs(a2 - a1) > 2 * M_PI) a2 = a1 + (negative ? -2 : 2) * M_PI;
    if (radius <= 0) { line_to(c, xc, yc); return 0; }
    line_to(c, xc + radius * cos(a1), yc + radius * sin(a1));
    // In y-down user space, increasing angles (CG's counterclockwise flag) turn clockwise, as in cairo.
    if (a1 != a2) CGPathAddArc(c->path, &state(c)->ctm, xc, yc, radius, a1, a2, negative);
    return 0;
}
static int l_arc(lua_State *L) { return arc(L, false); }
static int l_arc_negative(lua_State *L) { return arc(L, true); }

static int rectangle(lua_State *L) {
    Context *c = check_context(L);
    double x = luaL_checknumber(L, 2), y = luaL_checknumber(L, 3), w = luaL_checknumber(L, 4), h = luaL_checknumber(L, 5);
    move_to(c, x, y);
    line_to(c, x + w, y);
    line_to(c, x + w, y + h);
    line_to(c, x, y + h);
    CGPathCloseSubpath(c->path);
    return 0;
}

static int close_path(lua_State *L) {
    Context *c = check_context(L);
    if (c->has_point) CGPathCloseSubpath(c->path);
    return 0;
}

static void clear_path(lua_State *L, Context *c) {
    CGMutablePathRef path = CGPathCreateMutable();
    if (!path) fail(L, "out of memory");
    CGPathRelease(c->path);
    c->path = path;
    c->has_point = false;
}

static int new_path(lua_State *L) { clear_path(L, check_context(L)); return 0; }
static int new_sub_path(lua_State *L) { check_context(L)->has_point = false; return 0; }

// MARK: State

static int set_line_width(lua_State *L) {
    Context *c = check_context(L);
    double width = luaL_checknumber(L, 2);
    state(c)->line_width = width > 0 ? width : 0;
    return 0;
}

static int enum_value(lua_State *L, int maximum) {
    lua_Integer value = luaL_checkinteger(L, 2);
    if (value < 0 || value > maximum) luaL_argerror(L, 2, "invalid enum value");
    return (int)value;
}
static int set_line_cap(lua_State *L) { Context *c = check_context(L); state(c)->cap = enum_value(L, 2); return 0; }
static int set_line_join(lua_State *L) { Context *c = check_context(L); state(c)->join = enum_value(L, 2); return 0; }
static int set_fill_rule(lua_State *L) { Context *c = check_context(L); state(c)->fill_rule = enum_value(L, 1); return 0; }
static int set_miter_limit(lua_State *L) {
    Context *c = check_context(L);
    state(c)->miter_limit = luaL_checknumber(L, 2);
    return 0;
}

static void store_source(lua_State *L, Context *c, int pattern_index) {
    lua_getiuservalue(L, 1, 1);
    if (pattern_index) lua_pushvalue(L, pattern_index); else lua_pushnil(L);
    lua_rawseti(L, -2, c->depth + 1);
    lua_pop(L, 1);
}

static int set_source_rgba(lua_State *L) {
    Context *c = check_context(L);
    double r = luaL_checknumber(L, 2), g = luaL_checknumber(L, 3), b = luaL_checknumber(L, 4);
    double a = lua_isnoneornil(L, 5) ? 1 : luaL_checknumber(L, 5);
    store_source(L, c, 0);
    GState *s = state(c);
    s->pattern = NULL;
    s->r = clamp(r); s->g = clamp(g); s->b = clamp(b); s->a = clamp(a);
    return 0;
}

static int set_source(lua_State *L) {
    Context *c = check_context(L);
    Pattern *p = check_pattern(L, 2);
    store_source(L, c, 2);
    state(c)->pattern = p;
    state(c)->source_ctm = state(c)->ctm;
    return 0;
}

static int translate(lua_State *L) {
    Context *c = check_context(L);
    state(c)->ctm = CGAffineTransformTranslate(state(c)->ctm, luaL_checknumber(L, 2), luaL_checknumber(L, 3));
    return 0;
}

static int rotate(lua_State *L) {
    Context *c = check_context(L);
    state(c)->ctm = CGAffineTransformRotate(state(c)->ctm, luaL_checknumber(L, 2));
    return 0;
}

static int scale(lua_State *L) {
    Context *c = check_context(L);
    double sx = luaL_checknumber(L, 2), sy = luaL_checknumber(L, 3);
    if (sx == 0 || sy == 0 || !isfinite(sx) || !isfinite(sy)) return fail(L, "invalid scale");
    state(c)->ctm = CGAffineTransformScale(state(c)->ctm, sx, sy);
    return 0;
}

static int identity_matrix(lua_State *L) {
    state(check_context(L))->ctm = CGAffineTransformIdentity;
    return 0;
}

// MARK: Patterns

static int pattern_create(lua_State *L, bool radial) {
    int count = radial ? 6 : 4;
    double v[6] = {0};
    for (int index = 0; index < count; index++) v[index] = luaL_checknumber(L, index + 1);
    Pattern *p = lua_newuserdatauv(L, sizeof *p, 0);
    memset(p, 0, sizeof *p);
    luaL_setmetatable(L, PATTERN);
    p->radial = radial;
    if (radial) { p->x0 = v[0]; p->y0 = v[1]; p->r0 = v[2]; p->x1 = v[3]; p->y1 = v[4]; p->r1 = v[5]; }
    else { p->x0 = v[0]; p->y0 = v[1]; p->x1 = v[2]; p->y1 = v[3]; }
    return 1;
}
static int pattern_create_linear(lua_State *L) { return pattern_create(L, false); }
static int pattern_create_radial(lua_State *L) { return pattern_create(L, true); }

static int add_stop(lua_State *L, bool alpha) {
    Pattern *p = check_pattern(L, 1);
    Stop stop = {clamp(luaL_checknumber(L, 2)), clamp(luaL_checknumber(L, 3)), clamp(luaL_checknumber(L, 4)),
                 clamp(luaL_checknumber(L, 5)), alpha ? clamp(luaL_checknumber(L, 6)) : 1};
    if (p->count >= MAX_STOPS) return fail(L, "too many color stops");
    if (p->count == p->capacity) {
        int capacity = p->capacity ? p->capacity * 2 : 4;
        Stop *stops = realloc(p->stops, sizeof(Stop) * (size_t)capacity);
        if (!stops) return fail(L, "out of memory");
        p->stops = stops;
        p->capacity = capacity;
    }
    // Stable insertion: equal offsets keep the order in which they were added, as in cairo.
    int index = p->count;
    while (index > 0 && p->stops[index - 1].offset > stop.offset) { p->stops[index] = p->stops[index - 1]; index--; }
    p->stops[index] = stop;
    p->count++;
    CGGradientRelease(p->gradient);
    p->gradient = NULL;
    return 0;
}
static int add_stop_rgba(lua_State *L) { return add_stop(L, true); }
static int add_stop_rgb(lua_State *L) { return add_stop(L, false); }

static int pattern_destroy(lua_State *L) {
    Pattern *p = luaL_checkudata(L, 1, PATTERN);
    // A cairo_t may still use it as its source; the stops are freed by __gc.
    p->destroyed = true;
    return 0;
}

static int pattern_gc(lua_State *L) {
    Pattern *p = luaL_checkudata(L, 1, PATTERN);
    CGGradientRelease(p->gradient);
    p->gradient = NULL;
    free(p->stops);
    p->stops = NULL;
    p->count = p->capacity = 0;
    return 0;
}

static CGGradientRef _Nullable gradient(CGColorSpaceRef space, Pattern *p) {
    if (p->gradient || p->count == 0) return p->gradient;
    int count = p->count == 1 ? 2 : p->count;
    CGFloat components[MAX_STOPS * 4], locations[MAX_STOPS];
    for (int index = 0; index < count; index++) {
        Stop *stop = &p->stops[p->count == 1 ? 0 : index];
        locations[index] = p->count == 1 ? index : stop->offset;
        components[index * 4] = stop->r; components[index * 4 + 1] = stop->g;
        components[index * 4 + 2] = stop->b; components[index * 4 + 3] = stop->a;
    }
    p->gradient = CGGradientCreateWithColorComponents(space, components, locations, (size_t)count);
    return p->gradient;
}

// MARK: Drawing. No Lua error may be raised between CGContextSaveGState and its restore.

/// Expects the frame's base CTM; fills the current clip with the pattern (cairo EXTEND_PAD).
static void draw_pattern(lua_State *L, CGContextRef cg, GState *s) {
    CGGradientRef g = gradient(conky_self(L)->space, s->pattern);
    if (!g) return;
    Pattern *p = s->pattern;
    CGContextConcatCTM(cg, s->source_ctm);
    CGGradientDrawingOptions options = kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation;
    if (p->radial)
        CGContextDrawRadialGradient(cg, g, CGPointMake(p->x0, p->y0), p->r0, CGPointMake(p->x1, p->y1), p->r1, options);
    else
        CGContextDrawLinearGradient(cg, g, CGPointMake(p->x0, p->y0), CGPointMake(p->x1, p->y1), options);
}

static int stroke(lua_State *L, bool preserve) {
    Context *c = check_context(L);
    CGContextRef cg = target(L);
    GState *s = state(c);
    if (!CGPathIsEmpty(c->path)) {
        CGContextSaveGState(cg);
        CGContextBeginPath(cg);
        CGContextAddPath(cg, c->path);
        CGContextSaveGState(cg);
        CGContextConcatCTM(cg, s->ctm);  // Line width is measured in the cairo user space.
        CGContextSetLineWidth(cg, s->line_width);
        CGContextSetLineCap(cg, (CGLineCap)s->cap);
        CGContextSetLineJoin(cg, (CGLineJoin)s->join);
        CGContextSetMiterLimit(cg, s->miter_limit);
        if (!s->pattern) {
            CGContextSetRGBStrokeColor(cg, s->r, s->g, s->b, s->a);
            CGContextStrokePath(cg);
            CGContextRestoreGState(cg);
        } else {
            CGContextReplacePathWithStrokedPath(cg);
            CGContextRestoreGState(cg);  // The path is not part of the graphics state.
            if (!CGContextIsPathEmpty(cg)) { CGContextClip(cg); draw_pattern(L, cg, s); }
        }
        CGContextRestoreGState(cg);
    }
    if (!preserve) clear_path(L, c);
    return 0;
}
static int l_stroke(lua_State *L) { return stroke(L, false); }
static int l_stroke_preserve(lua_State *L) { return stroke(L, true); }

static int fill(lua_State *L, bool preserve) {
    Context *c = check_context(L);
    CGContextRef cg = target(L);
    GState *s = state(c);
    if (!CGPathIsEmpty(c->path)) {
        CGContextSaveGState(cg);
        CGContextBeginPath(cg);
        CGContextAddPath(cg, c->path);
        if (!s->pattern) {
            CGContextSetRGBFillColor(cg, s->r, s->g, s->b, s->a);
            if (s->fill_rule) CGContextEOFillPath(cg); else CGContextFillPath(cg);
        } else {
            if (s->fill_rule) CGContextEOClip(cg); else CGContextClip(cg);
            draw_pattern(L, cg, s);
        }
        CGContextRestoreGState(cg);
    }
    if (!preserve) clear_path(L, c);
    return 0;
}
static int l_fill(lua_State *L) { return fill(L, false); }
static int l_fill_preserve(lua_State *L) { return fill(L, true); }

static int paint(lua_State *L, double alpha) {
    Context *c = check_context(L);
    CGContextRef cg = target(L);
    GState *s = state(c);
    CGContextSaveGState(cg);
    CGContextSetAlpha(cg, clamp(alpha));
    if (!s->pattern) {
        CGContextSetRGBFillColor(cg, s->r, s->g, s->b, s->a);
        CGContextFillRect(cg, CGContextGetClipBoundingBox(cg));
    } else {
        draw_pattern(L, cg, s);
    }
    CGContextRestoreGState(cg);
    return 0;
}
static int l_paint(lua_State *L) { return paint(L, 1); }
static int l_paint_with_alpha(lua_State *L) { return paint(L, luaL_checknumber(L, 2)); }

void conky_cairo_open(lua_State *L) {
    luaL_newmetatable(L, SURFACE);
    lua_pop(L, 1);
    luaL_newmetatable(L, CONTEXT);
    lua_pushcfunction(L, context_gc);
    lua_setfield(L, -2, "__gc");
    lua_pop(L, 1);
    luaL_newmetatable(L, PATTERN);
    lua_pushcfunction(L, pattern_gc);
    lua_setfield(L, -2, "__gc");
    lua_pop(L, 1);

    const luaL_Reg functions[] = {
        {"cairo_xlib_surface_create", surface_create}, {"cairo_surface_destroy", surface_destroy},
        {"cairo_create", create}, {"cairo_destroy", destroy}, {"cairo_save", save}, {"cairo_restore", restore},
        {"cairo_new_path", new_path}, {"cairo_new_sub_path", new_sub_path}, {"cairo_move_to", l_move_to},
        {"cairo_line_to", l_line_to}, {"cairo_rel_move_to", rel_move_to}, {"cairo_rel_line_to", rel_line_to},
        {"cairo_curve_to", curve_to}, {"cairo_arc", l_arc}, {"cairo_arc_negative", l_arc_negative},
        {"cairo_rectangle", rectangle}, {"cairo_close_path", close_path},
        {"cairo_set_line_width", set_line_width}, {"cairo_set_line_cap", set_line_cap},
        {"cairo_set_line_join", set_line_join}, {"cairo_set_miter_limit", set_miter_limit},
        {"cairo_set_fill_rule", set_fill_rule}, {"cairo_set_source_rgba", set_source_rgba},
        {"cairo_set_source_rgb", set_source_rgba}, {"cairo_set_source", set_source},
        {"cairo_stroke", l_stroke}, {"cairo_stroke_preserve", l_stroke_preserve},
        {"cairo_fill", l_fill}, {"cairo_fill_preserve", l_fill_preserve},
        {"cairo_paint", l_paint}, {"cairo_paint_with_alpha", l_paint_with_alpha},
        {"cairo_translate", translate}, {"cairo_rotate", rotate}, {"cairo_scale", scale},
        {"cairo_identity_matrix", identity_matrix},
        {"cairo_pattern_create_linear", pattern_create_linear}, {"cairo_pattern_create_radial", pattern_create_radial},
        {"cairo_pattern_add_color_stop_rgba", add_stop_rgba}, {"cairo_pattern_add_color_stop_rgb", add_stop_rgb},
        {"cairo_pattern_destroy", pattern_destroy}, {NULL, NULL}};
    lua_pushglobaltable(L);
    luaL_setfuncs(L, functions, 0);
    const struct { const char *name; int value; } constants[] = {
        {"CAIRO_LINE_CAP_BUTT", 0}, {"CAIRO_LINE_CAP_ROUND", 1}, {"CAIRO_LINE_CAP_SQUARE", 2},
        {"CAIRO_LINE_JOIN_MITER", 0}, {"CAIRO_LINE_JOIN_ROUND", 1}, {"CAIRO_LINE_JOIN_BEVEL", 2},
        {"CAIRO_FILL_RULE_WINDING", 0}, {"CAIRO_FILL_RULE_EVEN_ODD", 1}};
    for (size_t index = 0; index < sizeof constants / sizeof *constants; index++) {
        lua_pushinteger(L, constants[index].value);
        lua_setfield(L, -2, constants[index].name);
    }
    lua_pop(L, 1);
}
