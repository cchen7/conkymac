#ifndef CONKY_LUA_INTERNAL_H
#define CONKY_LUA_INTERNAL_H

#include "ConkyLuaBridge.h"
#include <CoreText/CoreText.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#pragma clang assume_nonnull begin

#define FONT_CACHE_SIZE 32

/// One cached toy-API font; slots are reused least-recently-used first.
typedef struct {
    CTFontRef _Nullable font;
    char family[128];
    int slant, weight;
    double size;
    bool skew;  // Synthesised oblique: no italic face could be created.
    unsigned long long used;
} ConkyFont;

struct ConkyLua {
    lua_State *_Nullable L;
    size_t memory;
    CGContextRef _Nullable context;  // Only set while hooks run.
    CGColorSpaceRef _Nullable space;
    ConkyParseCallback parse;
    void *_Nullable parse_context;
    double fixed_time;
    double deadline;
    int budget_ms;
    int width, height;
    char *_Nullable conf_dir, *_Nullable lua_load, *_Nullable hook_pre, *_Nullable hook_post;
    char error[4096];
    ConkyFont fonts[FONT_CACHE_SIZE];  // cairo text; see Cairo.c
    unsigned long long font_clock;
};

static inline ConkyLua *_Nonnull conky_self(lua_State *_Nonnull L) { return *(ConkyLua **)lua_getextraspace(L); }
void conky_cairo_open(lua_State *_Nonnull L);
/// Releases the font cache; call after lua_close (finalizers may still run before that).
void conky_cairo_close(ConkyLua *_Nonnull self);

#pragma clang assume_nonnull end

#endif
