# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] - 2026-10-17

### Added

- `conky.text` rendering with CoreText:
  - colours, fonts, `goto`, `offset`, `voffset`, `alignr`, `alignc`, `tab`, `hr`, `stippled_hr` and bars
  - `if_match`/`if_up` conditions
  - the common system variables, with Conky's number formatting
- Themes that have only `conky.text`, without Lua hooks, now load.
- Lua cairo text: `select_font_face`, `set_font_size`, `show_text`, `text_path`, `text_extents`, `font_extents`, and the tolua `cairo_*_extents_t:create()` helpers.
- Lua cairo clipping (`clip`, `clip_preserve`, `reset_clip`), `set_operator` (`CLEAR`, `SOURCE`, `OVER`, `ADD`, `DEST`) and `set_dash`.
- `conky_parse` supports the same variables as `conky.text`.

### Security

- Template commands that run programs or read files (`exec*`, `lua_parse`, `cat`, `include`, `curl`, `if_existing`, ...) are never executed, and environment variables are not expanded.
- Hostile theme input is bounded: text, config and font sizes, cursor positions, rules, bars, dashes and caches all have limits.

### Known limitations

- Graphs (`cpugraph`, `downspeedgraph`, ...) are not drawn yet; their space is reserved.
- Icon fonts are not bundled.

## [0.1.1] - 2026-10-15

### Fixed

- CPU temperature showed N/A on M5. Temperature keys are now chosen per chip generation, and the frequency reader understands M5's cluster layout.

### Added

- `--sensors` prints what the temperature and frequency readers find, for bug reports on untested chips.

## 0.1.0 - 2026-10-15

First build, distributed as a signed and notarized DMG but not as a GitHub release.

- Transparent desktop panels on every display and in every Space, visible during Show Desktop.
- Built-in themes Simple Plus, Simple and Minimalis.
- CPU, P/E cluster frequency and load, temperature, memory, storage, battery, network and process ranking.
- Conky Lua themes with a CoreGraphics cairo subset (paths, arcs, gradients, transforms).
- Redrawing and detailed sampling pause while panels are covered.

[Unreleased]: https://github.com/cchen7/conkymac/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/cchen7/conkymac/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/cchen7/conkymac/releases/tag/v0.1.1
