#ifndef CONKY_LUA_BRIDGE_H
#define CONKY_LUA_BRIDGE_H

#include <CoreGraphics/CoreGraphics.h>

#pragma clang assume_nonnull begin

/// One Conky Lua theme: a config state that is discarded after loading and a script state
/// that persists. Not thread-safe; use from one thread. Lua errors never leave this library.
typedef struct ConkyLua ConkyLua;

/// Evaluates a Conky template. Must not throw or call back into the bridge. Returns a
/// malloc'd string (freed by the bridge) or NULL for an empty result.
typedef char *_Nullable (*ConkyParseCallback)(void *_Nullable context, const char *text);

/// Loads `conf_path` and its lua_load scripts. Never returns NULL except when out of memory;
/// check conky_lua_error. fixed_time >= 0 makes os.date/os.time use that UTC instant.
ConkyLua *_Nullable conky_lua_open(const char *conf_path, ConkyParseCallback parse,
                                   void *_Nullable parse_context, double fixed_time, int budget_ms);
int conky_lua_width(const ConkyLua *lua);
int conky_lua_height(const ConkyLua *lua);
/// Calls the pre and post draw hooks. The context's user space must be y-down Conky pixels.
/// Returns 0 on success; otherwise conky_lua_error describes the failure.
int conky_lua_draw(ConkyLua *lua, CGContextRef context);
/// The same hooks one at a time, so a renderer can draw conky.text between them as Conky does
/// (pre hook, text, post hook). A theme without that hook returns 0 without running anything.
int conky_lua_draw_pre(ConkyLua *lua, CGContextRef context);
int conky_lua_draw_post(ConkyLua *lua, CGContextRef context);
/// conky.text with its line breaks, or "" when the theme has none. Valid until conky_lua_close.
const char *conky_lua_text(const ConkyLua *lua);
/// The scalar conky.config entries (strings, numbers and booleans, as text), at most 256, keys
/// up to 64 and values up to 1024 bytes. Valid until conky_lua_close.
int conky_lua_config_count(const ConkyLua *lua);
const char *conky_lua_config_key(const ConkyLua *lua, int index);
const char *conky_lua_config_value(const ConkyLua *lua, int index);
/// Empty string when the last open/draw succeeded.
const char *conky_lua_error(const ConkyLua *lua);
void conky_lua_close(ConkyLua *_Nullable lua);

#pragma clang assume_nonnull end

#endif
