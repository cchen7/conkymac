# Third-party notices

## Stats

The RAM accounting formula and 64-bit network counter approach in
`Sources/ConkyMacCore/SystemCollector.swift` are adapted with reference to
[exelban/stats](https://github.com/exelban/stats), commit
`88d5359ad3466efaa16985646a0bb15c6599109f`, `Modules/RAM/readers.swift` and
`Modules/Net/readers.swift`. The read-only sensor code in
`Sources/ConkyMacCore/SensorCollector.swift` and the declarations in
`Sources/CSystemPrivate/include/CSystemPrivate.h` follow the same commit's
`SMC/smc.swift`, `Modules/CPU/readers.swift`, `Modules/CPU/bridge.h` and
`Kit/plugins/SystemKit.swift` (SMC key reads, IOReport residency and pmgr DVFS
tables); key selection and cluster averaging differ and are documented in
`docs/native-prototype-validation.md`. No Stats UI, database, helper, or fan
control is included.

MIT License

Copyright (c) 2019 Serhiy Mytrovtsiy

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Lua

`Sources/CLua` contains the unmodified library sources of
[Lua 5.4.9](https://www.lua.org/) from `https://www.lua.org/ftp/lua-5.4.9.tar.gz`
(SHA-256 `2335b6c582a52654f94612bf10d2f4672805d05329aa6568b1d8cd9e5c6fb8e6`),
without the `lua` and `luac` front ends. See also `Sources/CLua/LICENSE`.

MIT License

Copyright (C) 1994-2026 Lua.org, PUC-Rio.

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## cairo API names

`Sources/ConkyLuaBridge` exposes Lua functions named after the
[cairo](https://www.cairographics.org/) C API so existing Conky Lua scripts can
call them. It is an independent CoreGraphics implementation written from the
public API documentation; no cairo code is included or linked.

## Simple-Conky-theme

Visual reference selected by the user:
https://github.com/Abs-30/Simple-Conky-theme at
`5895d2e8b5e726f25db88826df252fad81bea3ed` (`Screenshot4.png`).
The checkout has no top-level license declaration. This prototype contains a
new native implementation inspired by the sidebar layout; no upstream scripts,
configuration, wallpaper, screenshots, or bundled fonts are redistributed.
See `docs/simple-theme-migration.md` for scope and visual differences.

## Minimalis Conky

Layout reference provided by the user: "Minimalis Conky 1.3" by archit3x
(conky.conf, December 2020; header says "Feel free to modify this script").
`Sources/ConkyMac/MinimalisTheme.swift` and the Simple Plus layout are new native
implementations of its arrangement. Its configuration, `ConkySymbols.ttf` font
and screenshot are not redistributed.

## Conky

Conky is a research and syntax reference. No Conky engine code is included in
this native prototype; the Lua theme host follows Conky's documented script
conventions (`conky_window`, `conky_parse`, `lua_load`, draw hooks). Future reuse
must retain its applicable GPL/BSD notices. Third-party Conky themes are not
redistributed.
