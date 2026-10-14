# ConkyMac

在 macOS 上实现原生桌面监控，并通过配置转换和脚本适配复用 Conky 生态中的外观主题。

目标是高性能原生 macOS 程序。内置三个 Swift/AppKit 原生主题，另可运行 Conky Lua/Cairo 主题：

- **Simple Plus**（默认）：[Simple-Conky-theme](https://github.com/Abs-30/Simple-Conky-theme) 的日期时钟 + Minimalis 的各分区（去掉 OS/Kernel），保持 Simple 的简洁视觉。
- **Simple**：Simple-Conky-theme 侧栏（时钟、CPU 历史图、电池、频率/温度、RAM、存储、网络、进程榜）。
- **Minimalis**：参考 archit3x 的 Minimalis Conky 1.3（蓝色分区标题、两列标签、细条）；用 SF Symbols 代替其字体，P/E 簇代替逐核行。

共享采集在后台串行队列以 1 Hz 运行：CPU（整机与逐核）、内存/Swap、网络、负载均值每秒；频率（IOReport）与温度（SMC）每 2 秒；进程榜（setuid `/bin/ps`）每 3 秒；磁盘容量和电池每 30 秒。

**当前状态**：Release 构建、Swift Testing 核心 14 项 + Lua 桥 8 项、宿主采样、双屏桌面与预览 GUI 烟测和性能测量已实测通过；用户实机确认双屏、显示桌面手势、图标避让与可读性。休眠/唤醒、Spaces 切换、显示器热插拔仍待手动验证。详见 [CHECKPOINT.md](CHECKPOINT.md) 和 [验证记录](docs/native-prototype-validation.md)。

## 构建与运行

需要现有 Xcode/Swift 6 工具链。编译最低系统暂设 macOS 14，尚未在 macOS 14 实机验证。无第三方包依赖、无需安装字体，构建产物默认放在 `/private/tmp/conkymac-build`。

```sh
zsh scripts/build-app.sh
open /private/tmp/conkymac-build/ConkyMac.app --args --preview
zsh scripts/validate.sh --gui
```

直接启动应用默认进入透明桌面模式：每块显示器右上角各一个面板，出现在所有 Spaces，触控板“显示桌面”手势时保持可见；主显示器额外左移 120pt 避开 Finder 桌面图标列。菜单栏提供 Preview、Show on Desktop、Theme、Hide 和 Quit。关闭预览窗口只隐藏并停止采集；Quit 才退出。当前会话没有安装或常驻运行该应用。

命令行选项：`--probe 5` 输出真实样本，`--render /tmp/simple.png` 输出固定输入 PNG，`--scale 1|2` 指定像素倍率，`--smoke 15` 运行 GUI 后自动退出，`--icon-margin N` 调整主显示器为桌面图标预留的右边距（0–600pt，默认 120）。`--theme ID|PATH` 选择内置主题（`simple-plus`、`simple`、`minimalis`）或 Conky Lua `.conf`（覆盖菜单保存的选择但不写入；与 `--render` 合用输出该主题的固定输入 PNG，`--render` 不带 `--theme` 时渲染 Simple），`--diagnostics` 额外在 stderr 报告未支持的 `conky_parse` 变量。`--interface en0` 可指定网络接口；默认使用系统主接口，可能是 VPN。`SESSION UP/DOWN` 只累计应用有效采样区间的所选接口流量，暂停区间不补算。

`CONKYMAC_BUILD_DIR` 可指定隔离构建目录。`validate.sh` 遇到指标不可用会以非零状态结束，不能将沙箱里的部分成功当成完整通过。天气、日历、GPU 占用、Conky 文本模板（`conky.text`）渲染和完整桌面行为矩阵仍待实现。温度与频率依赖私有接口（SMC、IOReport），只在 M4 Max / macOS 27 验证过，其他芯片可能显示 N/A。

## 打包发布（DMG）

`zsh scripts/package-dmg.sh` 生成 Developer ID 签名、Hardened Runtime、经 Apple 公证并钉票据的 `ConkyMac-<版本>.dmg`（仅 Apple Silicon），输出到 `~/Local/my-proj-temp/conkymac/dist/`。app 与 DMG 各公证、各钉票据一次，离线安装也能通过 Gatekeeper。

前置（一次性）：钥匙串里有且只有一个 “Developer ID Application” 证书（或用 `CONKYMAC_SIGN_IDENTITY` 指定）；用 `xcrun notarytool store-credentials conkymac-notary --apple-id <Apple ID> --team-id <Team ID>` 保存公证凭据（App 专用密码由该命令交互输入，存入钥匙串；`CONKYMAC_NOTARY_PROFILE` 可改名）。`CONKYMAC_SIGN_IDENTITY=-` 只做临时签名预演，不公证。

应用图标源文件是 `Resources/AppIcon.svg`（原创，呼应 Conky logo 的紫色与“C”，未使用其素材）；修改后运行 `zsh scripts/make-icon.sh` 重新生成 `AppIcon.icns`。

应用不需要任何 entitlement：SMC/IOReport 只读、`/bin/ps` 与 Lua 在 Hardened Runtime 下实测可用。

## Conky Lua 主题（CoreGraphics 版 cairo 子集）

不依赖 Cairo C 库：内置 Lua 5.4.9（`Sources/CLua`），由 C 桥 `Sources/ConkyLuaBridge` 在 CoreGraphics 上实现脚本可调用的 `cairo_*` 子集。所有 `lua_pcall` 与 Lua C 函数都在 C 里，Lua 错误不会穿过 Swift 栈。

- **主题目录**：`~/Library/Application Support/ConkyMac/Themes/<名称>/<文件>.conf`。菜单栏 Theme 子菜单列出三个内置主题与该目录下的 `*/*.conf`（每次打开菜单重新扫描），当前主题打勾，选择保存在 UserDefaults；已保存的文件被删除时回到默认的 Simple Plus。窗口尺寸跟随主题。本仓库不附带第三方主题脚本。
- **配置**：只读 Conky 1.10+ Lua 语法的 `conky.config`：`minimum_width`/`minimum_height`（16–4096，缺省 300）、`lua_load`（空格分隔；相对 `.conf` 所在目录；支持 `~`）、`lua_draw_hook_pre`/`lua_draw_hook_post`（自动补 `conky_` 前缀，可带空格分隔的字符串参数）。**`conky.text` 不渲染**；`update_interval` 被忽略，钩子随 1 Hz 采样每个快照执行一次。旧版（1.10 以前）文本配置不支持。
- **Lua 环境**：`conky_window`（width/height 等；display/drawable/visual 为占位值）、`conky_info`、`conky_parse`、`require 'cairo'`/`'cairo_xlib'`。不打开 `io`、`debug` 库；移除 `os.execute/exit/remove/rename/tmpname/setlocale` 与 `string.dump`；`.conf`、脚本、`load/loadfile/dofile/require` 只接受文本源码（拒绝预编译二进制块），不能加载 C 模块。每次加载或绘制有 250 ms 指令时间预算：超时后每条指令都报错，脚本自己的 `pcall`/协程吞不掉；终结器不受钩子约束，因此主题不能设置 Lua `__gc`，桥接层的 cairo 元表也已加锁。Lua 内存上限 128 MiB。纯 C 库调用内部（如长字符串的复杂 `string.find`）的耗时仍无法打断，`cairo_t` 路径的 CoreGraphics 内存也不计入上限。
- **`conky_parse`**：`${time 格式}`（strftime，本地时间）、`${cpu}`/`${cpu cpu0}`、`${cpu cpuN}`（逐核，`host_processor_info` 顺序）、`${memperc}`、`${fs_used_perc /}`（数据卷）、`${battery_percent}`、`${updates}`、`${uptime}`，以及 `$name` 与 `$$`。不可用的数值输出 `0`（与 Conky 一致）；未知变量输出空串。
- **cairo 子集**：`cairo_xlib_surface_create/surface_destroy/create/destroy/save/restore`，路径 `new_path/new_sub_path/move_to/line_to/rel_move_to/rel_line_to/curve_to/arc/arc_negative/rectangle/close_path`，状态 `set_line_width/line_cap/line_join/miter_limit/fill_rule/source_rgb(a)/source`，绘制 `stroke(_preserve)/fill(_preserve)/paint(_with_alpha)`，变换 `translate/rotate/scale/identity_matrix`，渐变 `pattern_create_linear/radial`、`pattern_add_color_stop_rgb(a)`、`pattern_destroy`，以及对应 `CAIRO_LINE_CAP_*`/`CAIRO_LINE_JOIN_*`/`CAIRO_FILL_RULE_*` 常量。**文字 API（`select_font_face`/`show_text`/`text_extents` 等）、clip、image surface、operator、dash、图片绘制尚未实现**；调用未实现的 `cairo_*`/`CAIRO_*` 名称会报错并指出名称。
- **错误与渲染**：脚本出错时面板显示错误摘要，应用继续运行，下一帧重试。钩子在主线程每个快照执行一次，画入倍率 `max(各屏 backingScaleFactor, 2)` 的离屏位图，多块显示器共用。桌面模式不给 Lua 主题叠加 Simple 的文字阴影：脚本自己决定阴影（如 Air Clock），额外透明层会改变原外观并增加合成成本。
- **固定渲染**：`--render out.png --theme X.conf` 使用 `Snapshot.fixture`、UTC 2026-05-06 14:17:00（`os.date`/`os.time` 同样固定）与 `${updates}`=100，重复渲染逐字节一致。仓库内测试主题见 `Tests/Fixtures/lua/arcs/`。

实测（Apple M4 Max，macOS 27，Release bundle，2× 位图）：Swift Testing 核心 14 项（含 3 项模板）与桥接 8 项通过；本地 rings + Air Clock 组合主题（340×182）在双屏桌面与预览模式 10–30 样本烟测均退出 0、无残留进程，`arcs` 主题同样通过。多次运行中每次 Lua 钩子 p50 2.6–6.6 ms、p95 4.2–8.2 ms（1 Hz，主线程，含位图光栅化），运行间波动明显；尚未 profile，也未移到后台队列。

## 调研与计划

- [会话交接 checkpoint](CHECKPOINT.md)
- [可行性分析](research/macos-feasibility.md)
- [任务拆解与验收标准](research/macos-roadmap.md)
- [Swift 原生架构与性能决策](research/swift-native-architecture.md)

上游 39 项 CTest 与本项目的 Swift 测试是两套独立结果。已有用 `ps`/`time` 测的 CPU、RSS 与绘制耗时（见验证记录），尚无 Instruments profile，也未做原主题逐像素迁移验收。

## 参考项目

- [Conky](https://github.com/brndnmtthws/conky)：模板、配置、绘图与主题生态；GPLv3-or-later，部分继承代码为 BSD。
- [Stats](https://github.com/exelban/stats)：macOS 与 Apple Silicon 采集实现；MIT。

后续复用代码与主题资源时保留相应许可和版权告知。
