#ifndef CONKY_LUA_INTERNAL_H
#define CONKY_LUA_INTERNAL_H

#include "ConkyLuaBridge.h"
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#pragma clang assume_nonnull begin

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
};

static inline ConkyLua *_Nonnull conky_self(lua_State *_Nonnull L) { return *(ConkyLua **)lua_getextraspace(L); }
void conky_cairo_open(lua_State *_Nonnull L);

#pragma clang assume_nonnull end

#endif
