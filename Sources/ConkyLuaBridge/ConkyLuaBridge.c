#include "Internal.h"
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <time.h>

#define MEMORY_LIMIT ((size_t)128 << 20)

static double now_ms(void) { return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6; }

static void *allocate(void *ud, void *ptr, size_t osize, size_t nsize) {
    ConkyLua *self = ud;
    size_t old = ptr ? osize : 0;
    if (nsize == 0) {
        free(ptr);
        self->memory -= old;
        return NULL;
    }
    if (nsize > old && self->memory + (nsize - old) > MEMORY_LIMIT) return NULL;
    void *result = realloc(ptr, nsize);
    if (result) self->memory = self->memory - old + nsize;
    return result;
}

static void budget_hook(lua_State *L, lua_Debug *ar) {
    (void)ar;
    ConkyLua *self = conky_self(L);
    if (now_ms() <= self->deadline) return;
    // Fire on every instruction from now on, so a script's own pcall/coroutine cannot absorb
    // the error and keep looping; protected_call restores the normal interval.
    lua_sethook(L, budget_hook, LUA_MASKCOUNT, 1);
    luaL_error(L, "script exceeded the %d ms time budget", self->budget_ms);
}

static lua_State *new_state(ConkyLua *self) {
    lua_State *L = lua_newstate(allocate, self);
    if (!L) return NULL;
    *(ConkyLua **)lua_getextraspace(L) = self;
    lua_sethook(L, budget_hook, LUA_MASKCOUNT, 10000);
    return L;
}

static int message_handler(lua_State *L) {
    const char *message = lua_tostring(L, 1);
    if (!message) {
        if (luaL_callmeta(L, 1, "__tostring") && lua_type(L, -1) == LUA_TSTRING) message = lua_tostring(L, -1);
        else message = lua_pushfstring(L, "(error object is a %s value)", luaL_typename(L, 1));
    }
    luaL_traceback(L, L, message, 1);
    return 1;
}

/// The only way bridge code enters Lua: errors stop at this pcall and become self->error.
static int protected_call(ConkyLua *self, lua_State *L, lua_CFunction function, void *argument) {
    lua_settop(L, 0);
    lua_pushcfunction(L, message_handler);
    lua_pushcfunction(L, function);
    lua_pushlightuserdata(L, argument);
    self->deadline = now_ms() + self->budget_ms;
    lua_sethook(L, budget_hook, LUA_MASKCOUNT, 10000);
    int status = lua_pcall(L, 1, 0, 1);
    if (status != LUA_OK) {
        const char *message = lua_type(L, -1) == LUA_TSTRING ? lua_tostring(L, -1) : "unknown Lua error";
        snprintf(self->error, sizeof self->error, "%s", message);
    } else {
        self->error[0] = 0;
    }
    lua_settop(L, 0);
    return status;
}

static void replace(char *_Nullable *slot, const char *_Nullable value) {
    free(*slot);
    *slot = value ? strdup(value) : NULL;
}

static int number_field(lua_State *L, const char *name, int fallback) {
    lua_getfield(L, -1, name);
    int isnum = 0;
    lua_Number value = lua_tonumberx(L, -1, &isnum);
    lua_pop(L, 1);
    if (!isnum || value != value) return fallback; // NaN would make the (int) cast undefined
    return value < 16 ? 16 : value > 4096 ? 4096 : (int)value;
}

static void string_field(lua_State *L, const char *name, char *_Nullable *slot) {
    lua_getfield(L, -1, name);
    replace(slot, lua_type(L, -1) == LUA_TSTRING ? lua_tostring(L, -1) : NULL);
    lua_pop(L, 1);
}

#define MAX_TEXT 65536
#define MAX_CONFIG_ENTRIES 256
#define MAX_CONFIG_KEY 64
#define MAX_CONFIG_VALUE 1024

/// True if the text has anything besides whitespace (`conky.text = [[ ]]` is common in Lua themes).
static int has_content(const char *_Nullable text) {
    return text && text[strspn(text, " \t\r\n")] != 0;
}

/// Copies the scalar entries of the table on top of the stack (conky.config). Anything else, and
/// entries over the length limits, is skipped; the Swift side only looks up what it knows.
static void copy_config(lua_State *L, ConkyLua *self) {
    self->config_keys = calloc(MAX_CONFIG_ENTRIES, sizeof *self->config_keys);
    self->config_values = calloc(MAX_CONFIG_ENTRIES, sizeof *self->config_values);
    if (!self->config_keys || !self->config_values) return;
    lua_pushnil(L);
    while (lua_next(L, -2) != 0) {
        // Key at -2 and value at -1; convert only copies so lua_next keeps working.
        if (self->config_count >= MAX_CONFIG_ENTRIES) { lua_pop(L, 2); break; }
        if (lua_type(L, -2) == LUA_TSTRING) {
            size_t key_length = 0, value_length = 0;
            const char *key = lua_tolstring(L, -2, &key_length);
            const char *value = NULL;
            int converted = 0;
            char flag[8];
            if (lua_type(L, -1) == LUA_TBOOLEAN) {
                snprintf(flag, sizeof flag, "%s", lua_toboolean(L, -1) ? "true" : "false");
                value = flag; value_length = strlen(flag);
            } else if (lua_type(L, -1) == LUA_TSTRING || lua_type(L, -1) == LUA_TNUMBER) {
                // Convert a copy (lua_next needs the original untouched) and keep it on the stack
                // until the bytes are copied out.
                lua_pushvalue(L, -1);
                converted = 1;
                value = lua_tolstring(L, -1, &value_length);
            }
            if (value && key_length > 0 && key_length <= MAX_CONFIG_KEY && value_length <= MAX_CONFIG_VALUE) {
                char *key_copy = strndup(key, key_length), *value_copy = strndup(value, value_length);
                if (key_copy && value_copy) {
                    self->config_keys[self->config_count] = key_copy;
                    self->config_values[self->config_count++] = value_copy;
                } else { free(key_copy); free(value_copy); }
            }
            if (converted) lua_pop(L, 1);
        }
        lua_pop(L, 1);
    }
}

// Themes are untrusted downloads: binary chunks can corrupt memory, so every loader is text-only.
static const char *const hardening =
    "local load, loadfile = load, loadfile\n"
    "_G.load = function(chunk, name, mode, ...)\n"
    "  if select('#', ...) > 0 then return load(chunk, name, 't', ...) end\n"
    "  return load(chunk, name, 't')\n"
    "end\n"
    "_G.loadfile = function(name, mode, ...)\n"
    "  if select('#', ...) > 0 then return loadfile(name, 't', ...) end\n"
    "  return loadfile(name, 't')\n"
    "end\n"
    "_G.dofile = function(name)\n"
    "  local chunk, message = loadfile(name, 't')\n"
    "  if not chunk then error(message, 2) end\n"
    "  return chunk()\n"
    "end\n"
    "string.dump = nil\n"
    // Finalizers run with hooks off, so a looping __gc would escape the time budget.
    "local setmetatable = setmetatable\n"
    "_G.setmetatable = function(t, mt)\n"
    "  if type(mt) == 'table' and rawget(mt, '__gc') ~= nil then error('__gc metamethods are not allowed in themes', 2) end\n"
    "  return setmetatable(t, mt)\n"
    "end\n"
    "if package then\n"
    "  package.cpath, package.loadlib = '', nil\n"
    "  package.searchers = {package.searchers[1], function(module)\n"
    "    local path, missing = package.searchpath(module, package.path)\n"
    "    if not path then return '\\n\\t' .. missing end\n"
    "    local chunk, message = loadfile(path, 't')\n"
    "    if not chunk then error(('error loading module \\'%s\\' from file \\'%s\\':\\n\\t%s'):format(module, path, message), 2) end\n"
    "    return chunk, path\n"
    "  end}\n"
    "end\n";

static void harden(lua_State *L) {
    if (luaL_loadbufferx(L, hardening, strlen(hardening), "=ConkyMac sandbox", "t") != LUA_OK) lua_error(L);
    lua_call(L, 0, 0);
}

static int load_config(lua_State *L) {
    ConkyLua *self = conky_self(L);
    const char *path = lua_touserdata(L, 1);
    const lua_CFunction libraries[] = {luaopen_base, luaopen_string, luaopen_table, luaopen_math, luaopen_utf8};
    const char *names[] = {LUA_GNAME, LUA_STRLIBNAME, LUA_TABLIBNAME, LUA_MATHLIBNAME, LUA_UTF8LIBNAME};
    for (int index = 0; index < 5; index++) { luaL_requiref(L, names[index], libraries[index], 1); lua_pop(L, 1); }
    harden(L);
    lua_newtable(L);
    lua_setglobal(L, "conky");
    if (luaL_loadfilex(L, path, "t") != LUA_OK)
        return luaL_error(L, "%s\n(only Lua-syntax conky.config files from Conky 1.10+ are supported)", lua_tostring(L, -1));
    lua_call(L, 0, 0);
    lua_getglobal(L, "conky");
    if (lua_type(L, -1) == LUA_TTABLE) lua_getfield(L, -1, "config");
    if (lua_type(L, -1) != LUA_TTABLE) return luaL_error(L, "%s: conky.config table is missing", path);
    self->width = number_field(L, "minimum_width", self->width);
    self->height = number_field(L, "minimum_height", self->height);
    string_field(L, "lua_load", &self->lua_load);
    string_field(L, "lua_draw_hook_pre", &self->hook_pre);
    string_field(L, "lua_draw_hook_post", &self->hook_post);
    copy_config(L, self);
    // The conky table sits just below conky.config.
    lua_getfield(L, -2, "text");
    if (lua_type(L, -1) == LUA_TSTRING) {
        size_t length;
        const char *text = lua_tolstring(L, -1, &length);
        if (length > MAX_TEXT) return luaL_error(L, "%s: conky.text is longer than %d bytes", path, MAX_TEXT);
        free(self->text);
        self->text = malloc(length + 1);
        if (!self->text) return luaL_error(L, "out of memory");
        memcpy(self->text, text, length + 1);
    }
    lua_pop(L, 1);
    return 0;
}

static void push_resolved(lua_State *L, const char *directory, const char *path, size_t length) {
    const char *home = getenv("HOME");
    if (path[0] == '~' && (length == 1 || path[1] == '/') && home) {
        lua_pushfstring(L, "%s%s", home, lua_pushlstring(L, path + 1, length - 1));
        lua_remove(L, -2);
    } else if (path[0] == '/') {
        lua_pushlstring(L, path, length);
    } else {
        lua_pushfstring(L, "%s/%s", directory, lua_pushlstring(L, path, length));
        lua_remove(L, -2);
    }
}

static const char *const environment =
    "local fixed = ...\n"
    "for _, name in ipairs({'execute', 'exit', 'remove', 'rename', 'tmpname', 'setlocale'}) do os[name] = nil end\n"
    "package.preload.cairo = function() return {} end\n"
    "package.preload.cairo_xlib = function() return {} end\n"
    "if fixed then\n"
    "  local date, time = os.date, os.time\n"
    "  os.date = function(format, t)\n"
    "    format = format or '%c'\n"
    "    if format:sub(1, 1) ~= '!' then format = '!' .. format end\n"
    "    return date(format, t or fixed)\n"
    "  end\n"
    "  os.time = function(t) if t == nil then return fixed end return time(t) end\n"
    "  os.clock = function() return 0 end\n"
    "end\n"
    "setmetatable(_G, {__index = function(_, name)\n"
    "  if type(name) == 'string' and (name:find('^cairo_') or name:find('^CAIRO_')) then\n"
    "    error(\"unsupported cairo API '\" .. name .. \"' (ConkyMac implements a CoreGraphics-backed subset)\", 2)\n"
    "  end\n"
    "end})\n";

static int conky_parse(lua_State *L);


static int setup_scripts(lua_State *L) {
    ConkyLua *self = conky_self(L);
    const lua_CFunction libraries[] = {luaopen_base, luaopen_package, luaopen_coroutine, luaopen_table,
                                       luaopen_string, luaopen_math, luaopen_utf8, luaopen_os};
    const char *names[] = {LUA_GNAME, LUA_LOADLIBNAME, LUA_COLIBNAME, LUA_TABLIBNAME,
                           LUA_STRLIBNAME, LUA_MATHLIBNAME, LUA_UTF8LIBNAME, LUA_OSLIBNAME};
    for (int index = 0; index < 8; index++) { luaL_requiref(L, names[index], libraries[index], 1); lua_pop(L, 1); }

    lua_createtable(L, 0, 12);
    const char *zero[] = {"text_start_x", "text_start_y", "border_inner_margin", "border_outer_margin", "border_width"};
    for (int index = 0; index < 5; index++) { lua_pushinteger(L, 0); lua_setfield(L, -2, zero[index]); }
    lua_pushinteger(L, self->width); lua_setfield(L, -2, "width");
    lua_pushinteger(L, self->height); lua_setfield(L, -2, "height");
    lua_pushinteger(L, self->width); lua_setfield(L, -2, "text_width");
    lua_pushinteger(L, self->height); lua_setfield(L, -2, "text_height");
    const char *handles[] = {"display", "drawable", "visual"};
    for (int index = 0; index < 3; index++) { lua_pushlightuserdata(L, NULL); lua_setfield(L, -2, handles[index]); }
    lua_setglobal(L, "conky_window");
    int cpus = 1;
    size_t size = sizeof cpus;
    sysctlbyname("hw.logicalcpu", &cpus, &size, NULL, 0);
    lua_createtable(L, 0, 3);
    lua_pushinteger(L, 1); lua_setfield(L, -2, "update_interval");
    lua_pushinteger(L, 1); lua_setfield(L, -2, "update_interval_on_battery");
    lua_pushinteger(L, cpus); lua_setfield(L, -2, "cpu_count");
    lua_setglobal(L, "conky_info");
    lua_register(L, "conky_parse", conky_parse);
    conky_cairo_open(L);

    // Scripts and `require` resolve relative to the theme directory, then each script's directory.
    lua_settop(L, 0);
    lua_newtable(L);
    int scripts = 0;
    const char *cursor = self->lua_load ? self->lua_load : "";
    for (;;) {
        cursor += strspn(cursor, " \t\r\n");
        size_t length = strcspn(cursor, " \t\r\n");
        if (length == 0) break;
        push_resolved(L, self->conf_dir, cursor, length);
        lua_rawseti(L, 1, ++scripts);
        cursor += length;
    }
    if (scripts == 0) return luaL_error(L, "conky.config.lua_load names no scripts");
    lua_getglobal(L, "package");
    lua_pushfstring(L, "%s/?.lua;%s/?/init.lua", self->conf_dir, self->conf_dir);
    for (int index = 1; index <= scripts; index++) {
        lua_rawgeti(L, 1, index);
        const char *path = lua_tostring(L, -1);
        const char *slash = strrchr(path, '/');
        lua_pushliteral(L, ";");
        lua_pushlstring(L, slash ? path : ".", slash ? (size_t)(slash - path) : 1);
        lua_pushliteral(L, "/?.lua");
        lua_remove(L, -4);
        lua_concat(L, 4);
    }
    lua_setfield(L, 2, "path");
    lua_settop(L, 1);

    harden(L);
    if (luaL_loadbufferx(L, environment, strlen(environment), "=ConkyMac environment", "t") != LUA_OK) return lua_error(L);
    if (self->fixed_time >= 0) lua_pushinteger(L, (lua_Integer)self->fixed_time); else lua_pushnil(L);
    lua_call(L, 1, 0);
    for (int index = 1; index <= scripts; index++) {
        lua_rawgeti(L, 1, index);
        if (luaL_loadfilex(L, lua_tostring(L, -1), "t") != LUA_OK) return lua_error(L);
        lua_call(L, 0, 0);
        lua_pop(L, 1);
    }
    return 0;
}

static int push_result(lua_State *L) {
    lua_pushstring(L, lua_touserdata(L, 1));
    return 1;
}

static int conky_parse(lua_State *L) {
    const char *text = luaL_checkstring(L, 1);
    ConkyLua *self = conky_self(L);
    luaL_checkstack(L, 2, NULL);
    char *result = self->parse ? self->parse(self->parse_context, text) : NULL;
    if (!result) { lua_pushliteral(L, ""); return 1; }
    // Copy under a nested pcall so an out-of-memory error cannot leak the malloc'd result.
    lua_pushcfunction(L, push_result);
    lua_pushlightuserdata(L, result);
    int status = lua_pcall(L, 1, 1, 0);
    free(result);
    if (status != LUA_OK) return lua_error(L);
    return 1;
}

static void run_hook(lua_State *L, const char *_Nullable spec) {
    if (!spec) return;
    const char *cursor = spec + strspn(spec, " \t");
    size_t length = strcspn(cursor, " \t");
    if (length == 0) return;
    if (length > 6 && strncmp(cursor, "conky_", 6) == 0) {
        lua_pushlstring(L, cursor, length);
    } else {
        lua_pushliteral(L, "conky_");
        lua_pushlstring(L, cursor, length);
        lua_concat(L, 2);
    }
    const char *name = lua_tostring(L, -1);
    if (lua_getglobal(L, name) != LUA_TFUNCTION) luaL_error(L, "draw hook %s is not a function", name);
    int arguments = 0;
    for (cursor += length;; cursor += length) {
        cursor += strspn(cursor, " \t");
        length = strcspn(cursor, " \t");
        if (length == 0) break;
        luaL_checkstack(L, 1, NULL);
        lua_pushlstring(L, cursor, length);
        arguments++;
    }
    lua_call(L, arguments, 0);
    lua_pop(L, 1);
}

static int pre_hook(lua_State *L) { run_hook(L, conky_self(L)->hook_pre); return 0; }
static int post_hook(lua_State *L) { run_hook(L, conky_self(L)->hook_post); return 0; }

ConkyLua *conky_lua_open(const char *conf_path, ConkyParseCallback parse, void *parse_context,
                         double fixed_time, int budget_ms) {
    ConkyLua *self = calloc(1, sizeof *self);
    if (!self) return NULL;
    self->parse = parse;
    self->parse_context = parse_context;
    self->fixed_time = fixed_time;
    self->budget_ms = budget_ms > 0 ? budget_ms : 250;
    self->width = 300;
    self->height = 300;
    self->space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    const char *slash = strrchr(conf_path, '/');
    self->conf_dir = slash ? strndup(conf_path, slash == conf_path ? 1 : (size_t)(slash - conf_path)) : strdup(".");
    if (!self->space || !self->conf_dir) { snprintf(self->error, sizeof self->error, "out of memory"); return self; }

    lua_State *config = new_state(self);
    if (!config) { snprintf(self->error, sizeof self->error, "cannot create a Lua state"); return self; }
    int status = protected_call(self, config, load_config, (void *)conf_path);
    lua_close(config);
    if (status != LUA_OK) return self;
    if (!self->hook_pre && !self->hook_post && !has_content(self->text)) {
        snprintf(self->error, sizeof self->error, "%s: the theme has no conky.text and sets neither lua_draw_hook_pre nor lua_draw_hook_post", conf_path);
        return self;
    }
    // A text-only theme needs no script state.
    if (!self->hook_pre && !self->hook_post) return self;
    self->L = new_state(self);
    if (!self->L) { snprintf(self->error, sizeof self->error, "cannot create a Lua state"); return self; }
    if (protected_call(self, self->L, setup_scripts, NULL) != LUA_OK) { lua_close(self->L); self->L = NULL; }
    return self;
}

static int draw_phase(ConkyLua *self, CGContextRef context, const char *_Nullable hook, lua_CFunction function) {
    if (!hook) return 0;
    if (!self->L) {
        if (!self->error[0]) snprintf(self->error, sizeof self->error, "theme is not loaded");
        return 1;
    }
    self->context = context;
    int status = protected_call(self, self->L, function, NULL);
    self->context = NULL;
    // Scripts often leak a cairo_t per frame; collect steadily so paths are released.
    lua_gc(self->L, LUA_GCSTEP, 0);
    return status != LUA_OK;
}

int conky_lua_draw_pre(ConkyLua *self, CGContextRef context) { return draw_phase(self, context, self->hook_pre, pre_hook); }
int conky_lua_draw_post(ConkyLua *self, CGContextRef context) { return draw_phase(self, context, self->hook_post, post_hook); }

int conky_lua_draw(ConkyLua *self, CGContextRef context) {
    if (!self->hook_pre && !self->hook_post && !self->L) {
        if (!self->error[0]) snprintf(self->error, sizeof self->error, "theme is not loaded");
        return 1;
    }
    return conky_lua_draw_pre(self, context) != 0 || conky_lua_draw_post(self, context) != 0;
}

void conky_lua_close(ConkyLua *self) {
    if (!self) return;
    // Finalizers may still call conky_parse while closing; never reach the Swift owner then.
    self->parse = NULL;
    if (self->L) lua_close(self->L);
    conky_cairo_close(self);
    CGColorSpaceRelease(self->space);
    free(self->conf_dir); free(self->lua_load); free(self->hook_pre); free(self->hook_post);
    free(self->text);
    for (int index = 0; index < self->config_count; index++) { free(self->config_keys[index]); free(self->config_values[index]); }
    free(self->config_keys); free(self->config_values);
    free(self);
}

int conky_lua_width(const ConkyLua *lua) { return lua->width; }
int conky_lua_height(const ConkyLua *lua) { return lua->height; }
const char *conky_lua_error(const ConkyLua *lua) { return lua->error; }
const char *conky_lua_text(const ConkyLua *lua) { return lua->text ? lua->text : ""; }
int conky_lua_config_count(const ConkyLua *lua) { return lua->config_count; }
const char *conky_lua_config_key(const ConkyLua *lua, int index) {
    return index >= 0 && index < lua->config_count ? lua->config_keys[index] : "";
}
const char *conky_lua_config_value(const ConkyLua *lua, int index) {
    return index >= 0 && index < lua->config_count ? lua->config_values[index] : "";
}
