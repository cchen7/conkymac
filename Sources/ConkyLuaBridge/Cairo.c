#include "Internal.h"
#include <math.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>

// A cairo API subset on CoreGraphics. Paths are kept per cairo_t in frame user space
// (Conky pixels, y-down); the cairo CTM is applied while building them, as cairo does.
// Text is the "toy" API: one glyph per character from CoreText, no shaping or kerning.

#define SURFACE "cairo_surface_t"
#define CONTEXT "cairo_t"
#define PATTERN "cairo_pattern_t"
#define MAX_DEPTH 16
#define MAX_STOPS 256
#define MAX_DASHES 32
#define MAX_CLIP 64                  // clip nodes chained in one cairo state
#define MAX_TEXT 4096                // UTF-8 bytes per text call
#define MAX_GLYPH_ELEMENTS 200000    // path elements text may add (reset by cairo_new_path)
#define MAX_COORDINATE 1e15          // largest CTM component
#define MAX_FONT_SIZE 1e4
#define OP_OVER 0                    // internal operator codes; 0 is the memset default
#define OP_CLEAR 1
#define OP_SOURCE 2
#define OP_ADD 3
#define OP_DEST 4

typedef struct { bool destroyed; } Surface;
typedef struct { double offset, r, g, b, a; } Stop;

typedef struct {
    bool destroyed, radial;
    double x0, y0, r0, x1, y1, r1;
    int count, capacity;
    Stop *_Nullable stops;
    CGGradientRef _Nullable gradient;
} Pattern;

/// Clip regions are immutable, reference-counted and shared by saved states. Paths are in
/// frame space; a NULL path clips everything. The CGContext does not keep clips between operations.
typedef struct Clip {
    int refs, length;
    CGPathRef _Nullable path;
    bool eofill;
    struct Clip *_Nullable parent;
} Clip;

typedef struct {
    CGAffineTransform ctm, source_ctm;
    double r, g, b, a, line_width, miter_limit, font_size, dash_offset, dash[MAX_DASHES];
    Pattern *_Nullable pattern;  // Kept alive by the context's uservalue table.
    Clip *_Nullable clip;
    int cap, join, fill_rule, slant, weight, op, dash_count;
    char family[128];
} GState;

typedef struct {
    bool destroyed, has_point;
    // A current point set by text, kept out of the path so repeated show_text calls do not grow it;
    // path operations that need a subpath flush it as a move_to (device space).
    bool pending;
    CGPoint pending_point;
    int glyph_elements;
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
                            .a = 1, .line_width = 2, .miter_limit = 10, .font_size = 10};
    return 1;
}

static void clip_release(Clip *_Nullable clip) {
    while (clip && --clip->refs == 0) {
        Clip *parent = clip->parent;
        CGPathRelease(clip->path);
        free(clip);
        clip = parent;
    }
}

static void release_context(Context *c) {
    CGPathRelease(c->path);
    c->path = NULL;
    for (int index = 0; index < MAX_DEPTH; index++) { clip_release(c->states[index].clip); c->states[index].clip = NULL; }
}

static int context_gc(lua_State *L) {
    Context *c = luaL_checkudata(L, 1, CONTEXT);
    release_context(c);
    c->destroyed = true; // a resurrected cairo_t must not reach CGPath calls with a NULL path
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
    if (c->states[c->depth].clip) c->states[c->depth].clip->refs++;
    c->depth++;
    return 0;
}

static int restore(lua_State *L) {
    Context *c = check_context(L);
    if (c->depth == 0) return fail(L, "cairo_restore without matching cairo_save");
    clip_release(state(c)->clip);
    state(c)->clip = NULL;
    c->depth--;
    lua_getiuservalue(L, 1, 1);
    lua_pushnil(L);
    lua_rawseti(L, -2, c->depth + 2);
    return 0;
}

// MARK: Paths

static void flush_point(Context *c) {
    if (!c->pending) return;
    CGPathMoveToPoint(c->path, NULL, c->pending_point.x, c->pending_point.y);
    c->pending = false;
}

static CGPoint current_point(Context *c) { return c->pending ? c->pending_point : CGPathGetCurrentPoint(c->path); }

static void move_to(Context *c, double x, double y) {
    CGPathMoveToPoint(c->path, &state(c)->ctm, x, y);
    c->has_point = true;
    c->pending = false;
}

static void line_to(Context *c, double x, double y) {
    if (!c->has_point) move_to(c, x, y);
    else { flush_point(c); CGPathAddLineToPoint(c->path, &state(c)->ctm, x, y); }
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
    CGPoint point = current_point(c);
    flush_point(c);
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
    flush_point(c);
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
    flush_point(c);
    if (c->has_point) CGPathCloseSubpath(c->path);
    return 0;
}

static void clear_path(lua_State *L, Context *c) {
    CGMutablePathRef path = CGPathCreateMutable();
    if (!path) fail(L, "out of memory");
    CGPathRelease(c->path);
    c->path = path;
    c->has_point = c->pending = false;
    c->glyph_elements = 0;
}

static int new_path(lua_State *L) { clear_path(L, check_context(L)); return 0; }
static int new_sub_path(lua_State *L) { Context *c = check_context(L); c->has_point = c->pending = false; return 0; }

// MARK: State

static int set_line_width(lua_State *L) {
    Context *c = check_context(L);
    double width = luaL_checknumber(L, 2);
    state(c)->line_width = width > 0 ? width : 0;
    return 0;
}

static int enum_value(lua_State *L, int index, int maximum) {
    lua_Integer value = luaL_checkinteger(L, index);
    if (value < 0 || value > maximum) luaL_argerror(L, index, "invalid enum value");
    return (int)value;
}
static int set_line_cap(lua_State *L) { Context *c = check_context(L); state(c)->cap = enum_value(L, 2, 2); return 0; }
static int set_line_join(lua_State *L) { Context *c = check_context(L); state(c)->join = enum_value(L, 2, 2); return 0; }
static int set_fill_rule(lua_State *L) { Context *c = check_context(L); state(c)->fill_rule = enum_value(L, 2, 1); return 0; }

// cairo values: CLEAR 0, SOURCE 1, OVER 2, DEST 6, ADD 12; the others (IN, XOR, blend modes...) are refused.
static int set_operator(lua_State *L) {
    Context *c = check_context(L);
    int op = enum_value(L, 2, 28);
    switch (op) {
    case 0: state(c)->op = OP_CLEAR; break;
    case 1: state(c)->op = OP_SOURCE; break;
    case 2: state(c)->op = OP_OVER; break;
    case 6: state(c)->op = OP_DEST; break;
    case 12: state(c)->op = OP_ADD; break;
    default: return luaL_error(L, "cairo_set_operator: operator %d is not supported (CLEAR, SOURCE, OVER, DEST and ADD are)", op);
    }
    return 0;
}

// cairo_set_dash(cr, {on, off, ...}, count, offset): count 0 turns dashing off.
static int set_dash(lua_State *L) {
    Context *c = check_context(L);
    luaL_checktype(L, 2, LUA_TTABLE);
    lua_Integer count = luaL_checkinteger(L, 3);
    double offset = luaL_checknumber(L, 4), values[MAX_DASHES], sum = 0;
    if (count < 0 || count > MAX_DASHES) return fail(L, "number of dashes must be between 0 and 32");
    if (!isfinite(offset)) return fail(L, "non-finite dash offset");
    for (int index = 0; index < count; index++) {
        int isnum = 0;
        lua_rawgeti(L, 2, index + 1);
        values[index] = lua_tonumberx(L, -1, &isnum);
        lua_pop(L, 1);
        if (!isnum || !isfinite(values[index]) || values[index] < 0) return fail(L, "dash lengths must be finite numbers >= 0");
        sum += values[index];
    }
    if (count > 0 && !(sum > 0)) return fail(L, "dash lengths must not all be zero");
    GState *s = state(c);
    memcpy(s->dash, values, sizeof(double) * (size_t)count);
    s->dash_count = (int)count;
    s->dash_offset = offset;
    return 0;
}
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

/// Every transform must leave the CTM finite, invertible and of sane size (cairo itself is fixed-point).
static int set_ctm(lua_State *L, Context *c, CGAffineTransform t) {
    const double v[6] = {t.a, t.b, t.c, t.d, t.tx, t.ty};
    double det = t.a * t.d - t.b * t.c;
    bool ok = isfinite(det) && det != 0;
    for (int index = 0; index < 6; index++) ok = ok && fabs(v[index]) <= MAX_COORDINATE;
    if (!ok) return fail(L, "the transformation would not be finite, invertible and within range");
    state(c)->ctm = t;
    return 0;
}

static int translate(lua_State *L) {
    Context *c = check_context(L);
    double tx = luaL_checknumber(L, 2), ty = luaL_checknumber(L, 3);
    return set_ctm(L, c, CGAffineTransformTranslate(state(c)->ctm, tx, ty));
}

static int rotate(lua_State *L) {
    Context *c = check_context(L);
    return set_ctm(L, c, CGAffineTransformRotate(state(c)->ctm, luaL_checknumber(L, 2)));
}

static int scale(lua_State *L) {
    Context *c = check_context(L);
    double sx = luaL_checknumber(L, 2), sy = luaL_checknumber(L, 3);
    if (sx == 0 || sy == 0 || !isfinite(sx) || !isfinite(sy)) return fail(L, "invalid scale");
    return set_ctm(L, c, CGAffineTransformScale(state(c)->ctm, sx, sy));
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

static const CGBlendMode blend_modes[] = {kCGBlendModeNormal, kCGBlendModeClear, kCGBlendModeCopy, kCGBlendModePlusLighter};

/// Saves the context state and applies what the CGContext does not keep for us: the clip and operator.
/// The path must be added afterwards (clipping consumes it); pair with CGContextRestoreGState.
static void begin(CGContextRef cg, const GState *s) {
    CGContextSaveGState(cg);
    for (Clip *clip = s->clip; clip; clip = clip->parent) {
        if (!clip->path) { CGContextClipToRect(cg, CGRectZero); continue; }
        CGContextBeginPath(cg);
        CGContextAddPath(cg, clip->path);
        if (clip->eofill) CGContextEOClip(cg); else CGContextClip(cg);
    }
    CGContextSetBlendMode(cg, blend_modes[s->op]);
}

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

typedef struct { CGPoint start, last; double length; } Measure;

static void measure_element(void *info, const CGPathElement *element) {
    Measure *m = info;
    int count = element->type == kCGPathElementAddCurveToPoint ? 3 : element->type == kCGPathElementAddQuadCurveToPoint ? 2
              : element->type == kCGPathElementCloseSubpath ? 0 : 1;
    for (int index = 0; index < count; index++) {
        CGPoint p = element->points[index];
        if (element->type != kCGPathElementMoveToPoint) m->length += hypot(p.x - m->last.x, p.y - m->last.y);
        m->last = p;
        if (element->type == kCGPathElementMoveToPoint) m->start = p;
    }
    if (element->type == kCGPathElementCloseSubpath) { m->length += hypot(m->start.x - m->last.x, m->start.y - m->last.y); m->last = m->start; }
}

/// A dash pattern much shorter than the path would make CoreGraphics emit billions of segments.
static bool dash_too_fine(const Context *c, const GState *s) {
    Measure m = {0};
    CGPathApply(c->path, &m, measure_element);
    double period = 0;
    for (int index = 0; index < s->dash_count; index++) period += s->dash[index];
    if (s->dash_count % 2) period *= 2;
    double scale = sqrt(fabs(s->ctm.a * s->ctm.d - s->ctm.b * s->ctm.c));
    return !(m.length / (period * scale) <= 1e5);
}

static int stroke(lua_State *L, bool preserve) {
    Context *c = check_context(L);
    CGContextRef cg = target(L);
    GState *s = state(c);
    if (s->op != OP_DEST && !CGPathIsEmpty(c->path)) {
        if (s->dash_count && dash_too_fine(c, s)) return fail(L, "the dash pattern is too fine for this path");
        begin(cg, s);
        CGContextBeginPath(cg);
        CGContextAddPath(cg, c->path);
        CGContextSaveGState(cg);
        CGContextConcatCTM(cg, s->ctm);  // Line width is measured in the cairo user space.
        CGContextSetLineWidth(cg, s->line_width);
        CGContextSetLineCap(cg, (CGLineCap)s->cap);
        CGContextSetLineJoin(cg, (CGLineJoin)s->join);
        CGContextSetMiterLimit(cg, s->miter_limit);
        if (s->dash_count) CGContextSetLineDash(cg, s->dash_offset, s->dash, (size_t)s->dash_count);
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

/// Fills `path` (frame space) with the source: solid colours, gradients, the clip and operator all apply.
static void fill_path(lua_State *L, CGContextRef cg, GState *s, CGPathRef path, bool eofill) {
    begin(cg, s);
    CGContextBeginPath(cg);
    CGContextAddPath(cg, path);
    if (!s->pattern) {
        CGContextSetRGBFillColor(cg, s->r, s->g, s->b, s->a);
        if (eofill) CGContextEOFillPath(cg); else CGContextFillPath(cg);
    } else {
        if (eofill) CGContextEOClip(cg); else CGContextClip(cg);
        draw_pattern(L, cg, s);
    }
    CGContextRestoreGState(cg);
}

static int fill(lua_State *L, bool preserve) {
    Context *c = check_context(L);
    CGContextRef cg = target(L);
    GState *s = state(c);
    if (s->op != OP_DEST && !CGPathIsEmpty(c->path)) fill_path(L, cg, s, c->path, s->fill_rule);
    if (!preserve) clear_path(L, c);
    return 0;
}
static int l_fill(lua_State *L) { return fill(L, false); }
static int l_fill_preserve(lua_State *L) { return fill(L, true); }

static int paint(lua_State *L, double alpha) {
    Context *c = check_context(L);
    CGContextRef cg = target(L);
    GState *s = state(c);
    if (s->op == OP_DEST) return 0;
    begin(cg, s);
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

// MARK: Clip

static int clip(lua_State *L, bool preserve) {
    Context *c = check_context(L);
    GState *s = state(c);
    if (s->clip && s->clip->length >= MAX_CLIP) return fail(L, "too many nested clips; wrap them in cairo_save/cairo_restore");
    Clip *node = malloc(sizeof *node);
    if (!node) return fail(L, "out of memory");
    // An empty path clips everything (path == NULL), as in cairo.
    CGPathRef path = CGPathIsEmpty(c->path) ? NULL : CGPathCreateCopy(c->path);
    if (!path && !CGPathIsEmpty(c->path)) { free(node); return fail(L, "out of memory"); }
    *node = (Clip){.refs = 1, .length = s->clip ? s->clip->length + 1 : 1, .path = path, .eofill = s->fill_rule != 0, .parent = s->clip};
    s->clip = node;  // The state's reference to its old clip now belongs to the new node.
    if (!preserve) clear_path(L, c);
    return 0;
}
static int l_clip(lua_State *L) { return clip(L, false); }
static int l_clip_preserve(lua_State *L) { return clip(L, true); }

static int reset_clip(lua_State *L) {
    GState *s = state(check_context(L));
    clip_release(s->clip);
    s->clip = NULL;
    return 0;
}

// MARK: Text. Fonts come from a small per-theme cache (Internal.h); nothing here holds a CF object
// across a Lua error, so every helper reports failure and the Lua function raises after cleanup.

static bool equals(const char *a, const char *b) { return strcasecmp(a, b) == 0; }

/// A 4 KiB string costs a few milliseconds in CoreText, so a loop of text calls could run far past the
/// count hook's interval; refuse once the time budget is spent (the hook then takes over for pcall loops).
static void check_time(lua_State *L) {
    ConkyLua *self = conky_self(L);
    if ((double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6 > self->deadline)
        luaL_error(L, "script exceeded the %d ms time budget", self->budget_ms);
}

static CTFontRef _Nullable make_font(const GState *s, bool *skew) {
    const char *family = s->family;
    CTFontRef base = NULL;
    if (!*family || equals(family, "sans") || equals(family, "sans-serif")) {
        base = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, s->font_size, NULL);
    } else {
        const char *name = equals(family, "serif") ? "Times" : equals(family, "monospace") ? "Menlo" : family;
        CFStringRef string = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
        if (string) { base = CTFontCreateWithName(string, s->font_size, NULL); CFRelease(string); }  // unknown names are substituted by CoreText
    }
    if (!base) base = CTFontCreateWithName(CFSTR("Helvetica"), s->font_size, NULL);
    if (!base) return NULL;
    *skew = s->slant == 2;
    CTFontSymbolicTraits traits = (s->weight ? kCTFontTraitBold : 0) | (s->slant == 1 ? kCTFontTraitItalic : 0);
    if (traits) {
        CTFontRef styled = CTFontCreateCopyWithSymbolicTraits(base, s->font_size, NULL, traits, traits);
        if (!styled && s->weight) styled = CTFontCreateCopyWithSymbolicTraits(base, s->font_size, NULL, kCTFontTraitBold, kCTFontTraitBold);
        if (styled) {
            if (s->slant == 1 && !(CTFontGetSymbolicTraits(styled) & kCTFontTraitItalic)) *skew = true;
            CFRelease(base);
            base = styled;
        } else if (s->slant == 1) {
            *skew = true;
        }
    }
    return base;
}

/// Least-recently-used lookup; the returned entry stays valid until the next call.
static ConkyFont *_Nullable font_for(ConkyLua *self, const GState *s) {
    ConkyFont *victim = NULL;
    for (int index = 0; index < FONT_CACHE_SIZE; index++) {
        ConkyFont *entry = &self->fonts[index];
        if (entry->font && entry->slant == s->slant && entry->weight == s->weight && entry->size == s->font_size &&
            strcmp(entry->family, s->family) == 0) {
            entry->used = ++self->font_clock;
            return entry;
        }
        if (!victim || (victim->font && (!entry->font || entry->used < victim->used))) victim = entry;
    }
    bool skew = false;
    CTFontRef font = make_font(s, &skew);
    if (!font) return NULL;
    if (victim->font) CFRelease(victim->font);
    snprintf(victim->family, sizeof victim->family, "%s", s->family);
    victim->font = font;
    victim->slant = s->slant;
    victim->weight = s->weight;
    victim->size = s->font_size;
    victim->skew = skew;
    victim->used = ++self->font_clock;
    return victim;
}

void conky_cairo_close(ConkyLua *self) {
    for (int index = 0; index < FONT_CACHE_SIZE; index++) {
        if (self->fonts[index].font) CFRelease(self->fonts[index].font);
        self->fonts[index].font = NULL;
    }
}

/// Next code point of UTF-8 that check_text accepted: no overlongs, surrogates or values above U+10FFFF.
static int utf8_next(const char *text, size_t length, size_t *index) {
    const unsigned char *s = (const unsigned char *)text + *index;
    size_t remaining = length - *index, count;
    int value;
    if (s[0] < 0x80) { (*index)++; return s[0]; }
    if (s[0] >= 0xC2 && s[0] <= 0xDF) { count = 2; value = s[0] & 0x1F; }
    else if (s[0] >= 0xE0 && s[0] <= 0xEF) { count = 3; value = s[0] & 0x0F; }
    else if (s[0] >= 0xF0 && s[0] <= 0xF4) { count = 4; value = s[0] & 0x07; }
    else return -1;
    if (count > remaining) return -1;
    for (size_t k = 1; k < count; k++) {
        if ((s[k] & 0xC0) != 0x80) return -1;
        value = value << 6 | (s[k] & 0x3F);
    }
    if ((count == 3 && value < 0x800) || (count == 4 && (value < 0x10000 || value > 0x10FFFF)) ||
        (value >= 0xD800 && value <= 0xDFFF)) return -1;
    *index += count;
    return value;
}

static const char *_Nullable check_text(const char *text, size_t length) {
    if (length > MAX_TEXT) return "text is longer than 4096 bytes";
    for (size_t index = 0; index < length;) if (utf8_next(text, length, &index) < 0) return "text is not valid UTF-8";
    return NULL;
}

typedef struct { double advance, x0, y0, x1, y1; bool ink, overflow; int elements; } Metrics;

static void count_element(void *info, const CGPathElement *element) { (void)element; ++*(int *)info; }

/// The face that has a glyph for the character: the font itself, the last fallback, or a new fallback.
static CTFontRef _Nullable find_glyph(CTFontRef font, CTFontRef _Nullable *fallback, const UniChar *units, CFIndex count, CGGlyph *glyph) {
    CGGlyph glyphs[2] = {0, 0};
    if (CTFontGetGlyphsForCharacters(font, units, glyphs, count) && glyphs[0]) { *glyph = glyphs[0]; return font; }
    if (*fallback && CTFontGetGlyphsForCharacters(*fallback, units, glyphs, count) && glyphs[0]) { *glyph = glyphs[0]; return *fallback; }
    CFStringRef string = CFStringCreateWithCharacters(NULL, units, count);
    if (!string) return NULL;
    CTFontRef other = CTFontCreateForString(font, string, CFRangeMake(0, count));
    CFRelease(string);
    if (!other) return NULL;
    if (!CTFontGetGlyphsForCharacters(other, units, glyphs, count) || !glyphs[0]) { CFRelease(other); return NULL; }
    if (*fallback) CFRelease(*fallback);
    *fallback = other;
    *glyph = glyphs[0];
    return other;
}

/// Lays out validated UTF-8 one glyph per character (no kerning or ligatures, like cairo's toy API) with the
/// baseline origin at user (x, y). Glyph outlines, when `out` is given, are added in frame space through
/// Scale(1,-1) · Translate(x + pen, y) · ctm (outlines are y-up, the frame y-down). Characters with no glyph are skipped.
static void typeset(const ConkyFont *font, double x, double y, CGAffineTransform ctm, const char *text, size_t length,
                    CGMutablePathRef _Nullable out, int budget, Metrics *m) {
    *m = (Metrics){0};
    CTFontRef fallback = NULL;
    CGAffineTransform skew = CGAffineTransformMake(1, 0, font->skew ? 0.2126 : 0, 1, 0, 0);
    CGAffineTransform flip = CGAffineTransformMakeScale(1, -1);
    for (size_t index = 0; index < length && !m->overflow;) {
        int code = utf8_next(text, length, &index);
        if (code < 0x20 || (code >= 0x7F && code < 0xA0)) continue;
        UniChar units[2];
        CFIndex count = 1;
        if (code >= 0x10000) { units[0] = (UniChar)(0xD800 + ((code - 0x10000) >> 10)); units[1] = (UniChar)(0xDC00 + ((code - 0x10000) & 0x3FF)); count = 2; }
        else units[0] = (UniChar)code;
        CGGlyph glyph = 0;
        CTFontRef face = find_glyph(font->font, &fallback, units, count, &glyph);
        if (!face) continue;
        CGSize advance = CGSizeZero;
        CTFontGetAdvancesForGlyphs(face, kCTFontOrientationHorizontal, &glyph, &advance, 1);
        CGRect box = CTFontGetBoundingRectsForGlyphs(face, kCTFontOrientationHorizontal, &glyph, NULL, 1);
        if (!CGRectIsNull(box) && (box.size.width > 0 || box.size.height > 0)) {
            double left = m->advance + box.origin.x, right = left + box.size.width, bottom = box.origin.y, top = bottom + box.size.height;
            if (!m->ink) { m->x0 = left; m->x1 = right; m->y0 = bottom; m->y1 = top; m->ink = true; }
            else { m->x0 = fmin(m->x0, left); m->x1 = fmax(m->x1, right); m->y0 = fmin(m->y0, bottom); m->y1 = fmax(m->y1, top); }
        }
        if (out) {
            CGAffineTransform t = CGAffineTransformConcat(skew, CGAffineTransformConcat(flip,
                CGAffineTransformConcat(CGAffineTransformMakeTranslation(x + m->advance, y), ctm)));
            CGPathRef outline = CTFontCreatePathForGlyph(face, glyph, &t);  // NULL for blank glyphs
            if (outline) {
                int elements = 0;
                CGPathApply(outline, &elements, count_element);
                if (elements > budget - m->elements) m->overflow = true;
                else { CGPathAddPath(out, NULL, outline); m->elements += elements; }
                CGPathRelease(outline);
            }
        }
        m->advance += advance.width;
    }
    if (fallback) CFRelease(fallback);
}

static bool user_point(Context *c, double *x, double *y) {
    *x = *y = 0;
    if (!c->has_point) return true;
    CGPoint p = CGPointApplyAffineTransform(current_point(c), CGAffineTransformInvert(state(c)->ctm));
    *x = p.x;
    *y = p.y;
    return isfinite(p.x) && isfinite(p.y);
}

static int l_get_current_point(lua_State *L) {
    Context *c = check_context(L);
    double x, y;
    if (!user_point(c, &x, &y)) return fail(L, "the current point is not finite");
    lua_pushnumber(L, x);
    lua_pushnumber(L, y);
    return 2;
}

static int select_font_face(lua_State *L) {
    Context *c = check_context(L);
    const char *family = luaL_checklstring(L, 2, NULL);
    int slant = enum_value(L, 3, 2), weight = enum_value(L, 4, 1);
    if (strlen(family) >= sizeof state(c)->family) return fail(L, "font name is too long");
    GState *s = state(c);
    snprintf(s->family, sizeof s->family, "%s", family);
    s->slant = slant;
    s->weight = weight;
    return 0;
}

static int set_font_size(lua_State *L) {
    Context *c = check_context(L);
    double size = luaL_checknumber(L, 2);
    if (!(size > 0 && size <= MAX_FONT_SIZE)) return fail(L, "font size must be a number in (0, 10000]");
    state(c)->font_size = size;
    return 0;
}

/// cairo_show_text draws at the current point (0,0 when there is none) and moves the point to where the
/// next glyph would go; cairo_text_path adds the outlines to the current path and moves it the same way.
static int text_operation(lua_State *L, bool draw) {
    Context *c = check_context(L);
    size_t length;
    const char *text = luaL_checklstring(L, 2, &length);
    CGContextRef cg = draw ? target(L) : NULL;
    check_time(L);
    const char *problem = check_text(text, length);
    GState *s = state(c);
    double x, y;
    if (!problem && !user_point(c, &x, &y)) problem = "the current point is not finite";
    ConkyFont *font = problem ? NULL : font_for(conky_self(L), s);
    if (!problem && !font) problem = "cannot create the font";
    CGMutablePathRef out = problem ? NULL : CGPathCreateMutable();
    if (!problem && !out) problem = "out of memory";
    if (!problem) {
        Metrics m;
        typeset(font, x, y, s->ctm, text, length, out, draw ? MAX_GLYPH_ELEMENTS : MAX_GLYPH_ELEMENTS - c->glyph_elements, &m);
        if (m.overflow) {
            problem = "the text would add too many path elements; call cairo_new_path or use a smaller string";
        } else {
            if (draw) { if (s->op != OP_DEST && !CGPathIsEmpty(out)) fill_path(L, cg, s, out, false); }
            else { CGPathAddPath(c->path, NULL, out); c->glyph_elements += m.elements; }
            c->has_point = c->pending = true;
            c->pending_point = CGPointApplyAffineTransform(CGPointMake(x + m.advance, y), s->ctm);
        }
    }
    CGPathRelease(out);
    return problem ? fail(L, problem) : 0;
}
static int show_text(lua_State *L) { return text_operation(L, true); }
static int text_path(lua_State *L) { return text_operation(L, false); }

static void set_number(lua_State *L, int table, const char *name, double value) {
    lua_pushstring(L, name);
    lua_pushnumber(L, value);
    lua_rawset(L, table);  // Raw: the table is script-owned and may carry a metatable.
}

static int text_extents(lua_State *L) {
    Context *c = check_context(L);
    size_t length;
    const char *text = luaL_checklstring(L, 2, &length);
    luaL_checktype(L, 3, LUA_TTABLE);
    check_time(L);
    const char *problem = check_text(text, length);
    ConkyFont *font = problem ? NULL : font_for(conky_self(L), state(c));
    if (!problem && !font) problem = "cannot create the font";
    if (problem) return fail(L, problem);
    Metrics m;
    typeset(font, 0, 0, CGAffineTransformIdentity, text, length, NULL, 0, &m);
    set_number(L, 3, "x_bearing", m.ink ? m.x0 : 0);
    set_number(L, 3, "y_bearing", m.ink ? -m.y1 : 0);  // negative above the baseline
    set_number(L, 3, "width", m.ink ? m.x1 - m.x0 : 0);
    set_number(L, 3, "height", m.ink ? m.y1 - m.y0 : 0);
    set_number(L, 3, "x_advance", m.advance);
    set_number(L, 3, "y_advance", 0);
    return 0;
}

static int font_extents(lua_State *L) {
    Context *c = check_context(L);
    luaL_checktype(L, 2, LUA_TTABLE);
    ConkyFont *font = font_for(conky_self(L), state(c));
    if (!font) return fail(L, "cannot create the font");
    double ascent = CTFontGetAscent(font->font), descent = CTFontGetDescent(font->font), leading = CTFontGetLeading(font->font);
    double width = CTFontGetBoundingBox(font->font).size.width;
    set_number(L, 2, "ascent", ascent);
    set_number(L, 2, "descent", descent);
    set_number(L, 2, "height", ascent + descent + leading);
    set_number(L, 2, "max_x_advance", width);
    set_number(L, 2, "max_y_advance", 0);
    return 0;
}

// tolua++ (Conky's binding layer) creates the extents structures with T:create() and manages their
// ownership; here they are plain tables and the ownership calls do nothing.
static int create_table(lua_State *L, const char *const *names) {
    lua_createtable(L, 0, 6);
    for (; *names; names++) { lua_pushnumber(L, 0); lua_setfield(L, -2, *names); }
    return 1;
}
static int create_text_extents(lua_State *L) {
    static const char *const names[] = {"x_bearing", "y_bearing", "width", "height", "x_advance", "y_advance", NULL};
    return create_table(L, names);
}
static int create_font_extents(lua_State *L) {
    static const char *const names[] = {"ascent", "descent", "height", "max_x_advance", "max_y_advance", NULL};
    return create_table(L, names);
}
static int do_nothing(lua_State *L) { (void)L; return 0; }

void conky_cairo_open(lua_State *L) {
    // Locked: scripts may not read or replace these metatables (e.g. install a Lua __gc).
    const char *names[] = {SURFACE, CONTEXT, PATTERN};
    const lua_CFunction finalizers[] = {NULL, context_gc, pattern_gc};
    for (int index = 0; index < 3; index++) {
        luaL_newmetatable(L, names[index]);
        if (finalizers[index]) { lua_pushcfunction(L, finalizers[index]); lua_setfield(L, -2, "__gc"); }
        lua_pushliteral(L, "locked");
        lua_setfield(L, -2, "__metatable");
        lua_pop(L, 1);
    }

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
        {"cairo_set_operator", set_operator}, {"cairo_set_dash", set_dash},
        {"cairo_clip", l_clip}, {"cairo_clip_preserve", l_clip_preserve}, {"cairo_reset_clip", reset_clip},
        {"cairo_select_font_face", select_font_face}, {"cairo_set_font_size", set_font_size},
        {"cairo_show_text", show_text}, {"cairo_text_path", text_path}, {"cairo_text_extents", text_extents},
        {"cairo_font_extents", font_extents}, {"cairo_get_current_point", l_get_current_point},
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
        {"CAIRO_FILL_RULE_WINDING", 0}, {"CAIRO_FILL_RULE_EVEN_ODD", 1},
        {"CAIRO_FONT_SLANT_NORMAL", 0}, {"CAIRO_FONT_SLANT_ITALIC", 1}, {"CAIRO_FONT_SLANT_OBLIQUE", 2},
        {"CAIRO_FONT_WEIGHT_NORMAL", 0}, {"CAIRO_FONT_WEIGHT_BOLD", 1},
        {"CAIRO_OPERATOR_CLEAR", 0}, {"CAIRO_OPERATOR_SOURCE", 1}, {"CAIRO_OPERATOR_OVER", 2},
        {"CAIRO_OPERATOR_DEST", 6}, {"CAIRO_OPERATOR_ADD", 12}};
    for (size_t index = 0; index < sizeof constants / sizeof *constants; index++) {
        lua_pushinteger(L, constants[index].value);
        lua_setfield(L, -2, constants[index].name);
    }
    // cairo_text_extents_t:create() / .create(), cairo_font_extents_t likewise, and the tolua helpers.
    const struct { const char *name; lua_CFunction create; } kinds[] = {
        {"cairo_text_extents_t", create_text_extents}, {"cairo_font_extents_t", create_font_extents}};
    for (int index = 0; index < 2; index++) {
        lua_createtable(L, 0, 2);
        lua_pushcfunction(L, kinds[index].create); lua_setfield(L, -2, "create");
        lua_pushcfunction(L, do_nothing); lua_setfield(L, -2, "destroy");
        lua_setfield(L, -2, kinds[index].name);
    }
    lua_createtable(L, 0, 2);
    lua_pushcfunction(L, do_nothing); lua_setfield(L, -2, "takeownership");
    lua_pushcfunction(L, do_nothing); lua_setfield(L, -2, "releaseownership");
    lua_setfield(L, -2, "tolua");
    lua_pop(L, 1);
}
