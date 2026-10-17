# Conky compatibility

ConkyMac reads Conky 1.10+ configuration files (the Lua syntax with `conky.config` and `conky.text`). It is not a Conky port: the semantics below were reimplemented by following Conky's source, and only what is listed here is supported. The older pre-1.10 text format is not supported.

A theme can use `conky.text`, Lua draw hooks, or both. Each snapshot is drawn in Conky's order: `lua_draw_hook_pre`, then `conky.text`, then `lua_draw_hook_post`.

## Configuration (`conky.config`)

| Setting | Behaviour |
| --- | --- |
| `minimum_width`, `minimum_height` | Panel size for Lua drawing (16–4096, default 300). With `conky.text`, the panel grows to fit the text. |
| `maximum_width` | Caps the text width. |
| `lua_load` | Space-separated script paths, relative to the `.conf` file; `~` is expanded. |
| `lua_draw_hook_pre`, `lua_draw_hook_post` | The `conky_` prefix is added if missing. Extra space-separated words are passed as string arguments. |
| `font` | fontconfig/Xft pattern, e.g. `DejaVu Sans Mono:size=9:bold`. Point sizes are converted to pixels at 96 dpi, as Xft does. |
| `default_color`, `color0`–`color9` | `#rrggbb`, `#rgb`, `#aarrggbb`, `#argb` (alpha first), or one of about 60 X11 colour names. |
| `uppercase`, `short_units`, `format_human_readable`, `top_name_width` | As in Conky. |
| `draw_shades` (default on, as in Conky), `default_shade_color`, `draw_outline`, `default_outline_color` | Text shadow and outline. |
| `default_bar_height` | Default 6. |
| `border_inner_margin`, `border_outer_margin`, `border_width` | Added around the text, as in Conky. |

Ignored: `update_interval` (the app samples at 1 Hz and draws once per snapshot), window settings (`alignment`, `gap_x`, `gap_y`, `own_window_*`, `double_buffer`), and anything not listed above.

## `conky.text`

### Syntax

- `$name`, `${name arguments}`, and `$$` for a literal `$`. Names are case-insensitive.
- Braces nest, so `${if_match ${cpu} > 50}` works. A `}` right after a bare `$name` is dropped, as in Conky (`$alignr}`).
- `$#rrggbb` and `${#rrggbb}` set the colour.
- `#` starts a comment and `\#` is a literal `#`. A backslash at the end of a line joins it to the next.
- Environment variables are **not** expanded: `$HOME` prints nothing.

### Layout

| Object | Notes |
| --- | --- |
| `color`, `colorN`, `#rrggbb` | `${color}` restores the default colour. Unknown names use the default colour. |
| `font` | `${font}` restores the default font. Fonts are looked up by name among installed fonts. |
| `goto X`, `offset X`, `voffset Y` | `goto` is in window coordinates; `voffset` accumulates into later lines. |
| `alignr [N]`, `alignc [N]` | Reserve the width of the rest of the line (text, bars, graphs). `alignr` defaults to 1. `alignc` never moves the cursor left. |
| `tab [step] [start]` | As in Conky. |
| `hr [height]`, `stippled_hr [gap] [height]` | Drawn at a quarter of the ascent above the baseline. |
| `cpubar`, `membar`, `swapbar`, `fs_bar`, `battery_bar` | `${cpubar cpu1 H,W}`; width 0 fills the rest of the line. |
| `cpugraph`, `downspeedgraph`, ... | **Not drawn yet**; the space is reserved. |

### Conditions

`if_match` (`<`, `>`, `<=`, `>=`, `==`, `!=`; numbers compare as numbers, anything else as strings), `if_up`, `else`, `endif`, nested to any depth. `if_existing` and `if_running` always evaluate as false.

### Variables

| Variables | Notes |
| --- | --- |
| `time`, `tztime` | strftime formats; local time unless a zone is given. |
| `cpu [cpuN]` | Integer percent. `cpu0` is the total; `cpu1` is the first core. |
| `mem`, `memmax`, `memfree`, `memeasyfree`, `memperc` | |
| `swap`, `swapmax`, `swapfree`, `swapperc` | |
| `fs_used`, `fs_size`, `fs_free`, `fs_used_perc` | Only `/` (the data volume). |
| `downspeed`, `upspeed`, `downspeedf`, `upspeedf`, `totaldown`, `totalup` | The interface argument is ignored: Linux names such as `wlan0` do not exist on macOS, so the active interface is used. Totals count from app start. |
| `uptime`, `uptime_short`, `loadavg [1\|2\|3]` | |
| `kernel`, `machine`, `sysname`, `nodename`, `nodename_short` | |
| `processes`, `running_processes` | |
| `freq [N]`, `freq_g [N]` | Frequency of the cluster that core N belongs to. |
| `acpitemp` | CPU temperature in °C. |
| `top TYPE N`, `top_mem TYPE N` | TYPE is `name`, `cpu`, `pid`, `mem` or `mem_res`; N is 1–10. `vsize` and `user` are not collected. |
| `battery_percent`, `battery_short` | |

Numbers are formatted as Conky formats them: `human_readable` keeps three significant digits (`23.4GiB`), `top` columns are padded the same way, and unavailable numbers print `0`. Unknown variables, and variables with no macOS data (`wireless_*`, GPU, `hwmon`, ...), print nothing.

### Blocked commands

These print nothing and are never run: `exec`, `execi`, `execp`, `execpi`, `execbar`, `execgauge`, `execgraph` (and their `i` variants), `texeci`, `texecpi`, `lua`, `lua_parse`, `lua_bar`, `lua_gauge`, `lua_graph`, `include`, `eval`, `cat`, `catp`, `head`, `tail`, `curl`, `rss`, `weather`, `read_tcp`, `read_udp`, `image`, `stdin`, `pre_exec`, `if_existing`, `if_running`. This is a deliberate decision, because themes are usually downloaded from the internet. Run with `--diagnostics` to list what a theme tried to use.

### Panel size

With `conky.text`, the panel only ever grows: text width changes every second, and a panel that shrank and grew would shake. It is capped at 1500 × 3000 pt.

## Lua

### Environment

- `conky_window` has `width` and `height`. `text_start_x`, `text_start_y` and the border fields are 0, and `display`, `drawable` and `visual` are placeholders.
- `conky_info` and `conky_parse` are available.
- `require 'cairo'` and `require 'cairo_xlib'` succeed and expose the functions below.
- `conky_parse` uses the same evaluator as `conky.text`, so it supports the variables listed above plus `${updates}`. Layout objects print nothing.

### cairo subset

The functions are implemented with CoreGraphics; the cairo library is not used. Anti-aliasing and gradient interpolation are close to cairo's but not pixel-identical.

| Area | Functions |
| --- | --- |
| Surfaces and contexts | `cairo_xlib_surface_create`, `cairo_surface_destroy`, `cairo_create`, `cairo_destroy`, `cairo_save`, `cairo_restore` |
| Paths | `new_path`, `new_sub_path`, `move_to`, `line_to`, `rel_move_to`, `rel_line_to`, `curve_to`, `arc`, `arc_negative`, `rectangle`, `close_path`, `get_current_point` |
| State | `set_line_width`, `set_line_cap`, `set_line_join`, `set_miter_limit`, `set_fill_rule`, `set_source_rgb`, `set_source_rgba`, `set_source`, `set_operator`, `set_dash` |
| Drawing | `stroke`, `stroke_preserve`, `fill`, `fill_preserve`, `paint`, `paint_with_alpha` |
| Transforms | `translate`, `rotate`, `scale`, `identity_matrix` |
| Gradients | `pattern_create_linear`, `pattern_create_radial`, `pattern_add_color_stop_rgb`, `pattern_add_color_stop_rgba`, `pattern_destroy` |
| Text | `select_font_face`, `set_font_size`, `show_text`, `text_path`, `text_extents`, `font_extents` |
| Clipping | `clip`, `clip_preserve`, `reset_clip` |
| Constants | `CAIRO_LINE_CAP_*`, `CAIRO_LINE_JOIN_*`, `CAIRO_FILL_RULE_*`, `CAIRO_FONT_SLANT_*`, `CAIRO_FONT_WEIGHT_*`, `CAIRO_OPERATOR_CLEAR/SOURCE/OVER/ADD/DEST` |

Details:

- **Text** follows cairo's "toy" API: one glyph per character, without kerning, ligatures or shaping. `y` is the baseline. `sans`/`sans-serif` map to the system font, `serif` to Times and `monospace` to Menlo; other names go to CoreText. Characters missing from the font use a CoreText fallback font. Bold and italic use font traits; when no italic face exists, the text is slanted.
- `cairo_text_extents_t:create()` and `cairo_font_extents_t:create()` return plain tables that `cairo_text_extents` and `cairo_font_extents` fill in. `tolua.takeownership` and `tolua.releaseownership` are no-ops.
- **Clipping** is saved and restored with `cairo_save`/`cairo_restore`, up to 64 nested clips.
- **Operators**: `CLEAR`, `SOURCE`, `OVER`, `ADD` and `DEST`; others raise an error.
- **Dashes**: up to 32 entries; they scale with the transform.

**Not implemented:** `cairo_mask`, `cairo_set_font_matrix` and scaled fonts, image surfaces and image drawing, and the other operators. Calling an unimplemented `cairo_*` function or `CAIRO_*` constant raises an error that names it.

**Known differences:** `text_extents` ignores the synthetic slant. Stroking glyph outlines can show where a font's contours overlap.

## Security model

Conky themes are usually downloaded, so ConkyMac treats them as untrusted.

- **No commands, no files.** Template commands that run programs or read files are never executed (see [Blocked commands](#blocked-commands)). Environment variables are not expanded. Theme font files are not installed or loaded automatically.
- **Lua sandbox.** The `io` and `debug` libraries are not loaded. `os.execute`, `os.exit`, `os.remove`, `os.rename`, `os.tmpname`, `os.setlocale` and `string.dump` are removed. C modules cannot be loaded.
- **Text-only code.** The `.conf` file, `lua_load` scripts, `load`, `loadfile`, `dofile` and `require` accept only source text; precompiled bytecode, which can corrupt memory, is rejected.
- **Time budget.** Loading and each draw hook get 250 ms of Lua execution. Once the budget is spent, every further instruction fails, so a script's own `pcall` or coroutines cannot swallow the timeout. Because finalizers run without the hook, themes cannot set `__gc` metamethods, and the bridge's metatables are locked.
- **Memory.** Lua memory is capped at 128 MiB.
- **Bounded inputs.**
  - `conky.text` may be up to 64 KiB, and only 256 config entries (1 KiB each) are read.
  - Text strings passed to cairo may be up to 4 KiB of valid UTF-8, and font sizes up to 10,000.
  - Transforms must stay finite and invertible.
  - Sizes, positions, dash counts and the font and line caches are all capped. Non-finite numbers are rejected.
- **Errors stay contained.** A script error is shown on the panel, the app keeps running, and the next snapshot tries again.

Some limits remain:

- Time spent inside a single C library call (for example a pathological `string.find` on a long string) cannot be interrupted.
- CoreGraphics memory used by cairo paths does not count toward the Lua limit.
- A long-lived `cairo_t` that keeps adding path segments without stroking or filling grows, as it would in cairo.
