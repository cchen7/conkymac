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
    if (now_ms() > self->deadline) luaL_error(L, "script exceeded the %d ms time budget", self->budget_ms);
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
    if (!isnum) return fallback;
    return value < 16 ? 16 : value > 4096 ? 4096 : (int)value;
}

static void string_field(lua_State *L, const char *name, char *_Nullable *slot) {
    lua_getfield(L, -1, name);
    replace(slot, lua_type(L, -1) == LUA_TSTRING ? lua_tostring(L, -1) : NULL);
    lua_pop(L, 1);
}

static int load_config(lua_State *L) {
    ConkyLua *self = conky_self(L);
    const char *path = lua_touserdata(L, 1);
    const lua_CFunction libraries[] = {luaopen_base, luaopen_string, luaopen_table, luaopen_math, luaopen_utf8};
    const char *names[] = {LUA_GNAME, LUA_STRLIBNAME, LUA_TABLIBNAME, LUA_MATHLIBNAME, LUA_UTF8LIBNAME};
    for (int index = 0; index < 5; index++) { luaL_requiref(L, names[index], libraries[index], 1); lua_pop(L, 1); }
    lua_newtable(L);
    lua_setglobal(L, "conky");
    if (luaL_loadfile(L, path) != LUA_OK)
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
    "package.cpath, package.loadlib = '', nil\n"
    "for index = #package.searchers, 3, -1 do package.searchers[index] = nil end\n"
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

    if (luaL_loadbuffer(L, environment, strlen(environment), "=ConkyMac environment") != LUA_OK) return lua_error(L);
    if (self->fixed_time >= 0) lua_pushinteger(L, (lua_Integer)self->fixed_time); else lua_pushnil(L);
    lua_call(L, 1, 0);
    for (int index = 1; index <= scripts; index++) {
        lua_rawgeti(L, 1, index);
        if (luaL_loadfile(L, lua_tostring(L, -1)) != LUA_OK) return lua_error(L);
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
    char *result = self->parse(self->parse_context, text);
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

static int draw_hooks(lua_State *L) {
    ConkyLua *self = conky_self(L);
    run_hook(L, self->hook_pre);
    run_hook(L, self->hook_post);
    return 0;
}

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
    if (!self->hook_pre && !self->hook_post) {
        snprintf(self->error, sizeof self->error, "%s: conky.config sets neither lua_draw_hook_pre nor lua_draw_hook_post", conf_path);
        return self;
    }
    self->L = new_state(self);
    if (!self->L) { snprintf(self->error, sizeof self->error, "cannot create a Lua state"); return self; }
    if (protected_call(self, self->L, setup_scripts, NULL) != LUA_OK) { lua_close(self->L); self->L = NULL; }
    return self;
}

int conky_lua_draw(ConkyLua *self, CGContextRef context) {
    if (!self->L) {
        if (!self->error[0]) snprintf(self->error, sizeof self->error, "theme is not loaded");
        return 1;
    }
    self->context = context;
    int status = protected_call(self, self->L, draw_hooks, NULL);
    self->context = NULL;
    // Scripts often leak a cairo_t per frame; collect steadily so paths are released.
    lua_gc(self->L, LUA_GCSTEP, 0);
    return status != LUA_OK;
}

void conky_lua_close(ConkyLua *self) {
    if (!self) return;
    if (self->L) lua_close(self->L);
    CGColorSpaceRelease(self->space);
    free(self->conf_dir); free(self->lua_load); free(self->hook_pre); free(self->hook_post);
    free(self);
}

int conky_lua_width(const ConkyLua *lua) { return lua->width; }
int conky_lua_height(const ConkyLua *lua) { return lua->height; }
const char *conky_lua_error(const ConkyLua *lua) { return lua->error; }
