# ConkyMac 会话交接 checkpoint

记录日期：2026-10-14。新会话先读本文件，再读取下面的架构和任务文档。读取后核对当前 Git 状态与用户最新要求，不要重复完成已有调研。

## 0. 最新接续状态（优先于下面的初始调研归档）

更新：2026-10-14 晚，审批恢复后已继续。首个参考主题：[Abs-30/Simple-Conky-theme](https://github.com/Abs-30/Simple-Conky-theme)。用户要求：可 worktree/subagent 并行、必须 code review、做好版本管理。

### 读取顺序

1. 本节；[当前实施计划](docs/implementation-plan.md)。
2. [原生原型实现、审查与验证](docs/native-prototype-validation.md)（含宿主验证与网络计数器发现）。
3. [主题迁移范围](docs/simple-theme-migration.md)、[Swift 架构](research/swift-native-architecture.md)、[路线图](research/macos-roadmap.md)。

### Git

- `main` = `bbfe390` 调研基线。功能分支 `feat/simple-native-sidebar`：`e33b196` 迁移文档、`dcbdfa2` 原型，其后为宿主验证与网络回绕修复提交（见 `git log`）。
- 文档 worktree `/private/tmp/conkymac-theme-docs-20261014`（分支 `docs/simple-theme-plan`，停在 `e33b196`，内容已在功能分支中）可删除，待用户确认。
- 未 push、未合并 main。

### 已验证（宿主实测）

- Release 构建；Swift Testing 5/5；1×/2× 固定输入渲染。
- `--probe 5` 全项 `SAMPLE_CHECK_OK`（含 uptime）。
- bundle 预览与桌面模式烟测退出 0、无残留；桌面窗口透明、鼠标穿透、位于桌面图标层 −1；截图确认实时数据绘制。之前的 exit 134 仅在执行沙箱。
- 120 秒基线：CPU 时间 0.71 s、RSS ≈83 MiB 平稳、线程 ≤17、绘制 p95 2.49 ms、采集 p95 1.03 ms。
- 发现并修复：macOS 27 对本进程的网络字节计数截为 32 位且 1 KiB 取整；现按 32 位回绕处理。

### 未完成

- 手动：菜单栏 Hide/Show/Preview 点击、真实休眠/唤醒、Spaces/多屏/Stage Manager。
- Instruments profile、小时级内存曲线、macOS 14 实机。
- 频率/温度（N/A）、天气/日历/GPU/进程榜、Lua/Cairo 路径。P1/P2 不得标记完成。

### 构建与证据

`zsh scripts/build-app.sh`、`zsh scripts/swift.sh test -c release`、`zsh scripts/validate.sh [--gui]`；构建缓存 `/private/tmp/conkymac-build`。宿主证据 `/private/tmp/conkymac-validation-host/`（可能被系统清理，摘要已入文档）；一次性探针源码在 `~/Local/my-proj-temp/conkymac/netprobe/`。

---

**以下第 1–9 节是接续前的初始调研归档；涉及“尚无应用代码/尚无提交”等状态，以第 0 节为准。**

## 1. 工作目录与仓库

**后续开发目录：`/Users/chenxin/Local/conkymac`。** 本次会话的初始工作目录仍是 `/Users/chenxin/Local/conky`，但那个目录是上游参考，不是新应用的开发仓库。

| 用途 | 目录/仓库 | 检查时状态 |
| --- | --- | --- |
| ConkyMac 主项目 | `/Users/chenxin/Local/conkymac`；`https://github.com/cchen7/conkymac.git` | 分支 main，尚无本地提交；README.md 与 research/ 均未跟踪；尚未推送 |
| Conky 上游参考 | `/Users/chenxin/Local/conky`；`https://github.com/brndnmtthws/conky.git` | 提交 `0bee35ce5befb7d84bb7494cd83c2313dac75387`；仅 research/ 未跟踪；未修改引擎 |
| Stats 临时参考 | `/private/tmp/conky-feasibility-20261014/stats` | 提交 `88d5359ad3466efaa16985646a0bb15c6599109f`；临时浅克隆 |

本文件创建后，ConkyMac 还会多一个未跟踪的 CHECKPOINT.md。所有未提交文件应保留；没有执行 commit、push、应用安装、服务安装或传感器写入。

## 2. 用户明确的目标与偏好

- 做一个**高性能的原生 macOS 桌面监控程序**。
- 复用 Conky 生态里漂亮的主题/皮肤；允许转换配置、修改 Lua 和替换平台数据源。
- 不要求完全兼容所有历史配置、变量和脚本。
- 开发使用 `cchen7/conkymac`；Conky 保留作参考。
- 用户指定参考 `exelban/stats` 的原生传感器采集方式。
- 本机硬件很强，编译应高效：已确认 Apple M4 Max、16 核 CPU、64 GiB 内存。后续普通编译使用 16 路并行、复用增量构建；不要为更新文档重复编译。
- 当前只完成调研和架构评估，尚未开始原生应用实现。用户尚未指定具体验收主题。

## 3. 当前推荐方案

这是最近一次评估提出并写入文档的方案；用户已明确原生/性能目标，但尚未逐项确认全部实现选型。

- **Swift 原生运行核心**：应用/窗口、共享采集、调度与缓存、主题模型、必要模板子集、原生渲染。
- AppKit 管理桌面窗口；原生主题使用 CoreGraphics/CoreText/Core Animation。设置界面可用 SwiftUI。
- **Lua/Cairo 作为主题适配层**：复杂现有绘图先保留，按主题逐步转换。Swift 可以作为 Lua 宿主，无需把整个 Conky C++ 程序作为宿主。
- Conky 主要作为语法和主题行为参考；不直接绑定其全局主循环及采集调度。实际复制代码时仍须遵守许可。
- Stats 按需参考采集算法、传感器映射和单位换算，不引入完整 Stats Kit/UI/数据库/风扇控制体系。
- 性能靠共享采样、解析缓存、静态内容缓存、变化驱动更新及正确算法。Swift 不天然比 C++ 快；尚无新应用的性能对照数据。
- 原生与 Lua/Cairo 两条路径分别建立视觉及性能基线。暂不引入 Metal，没有已测 GPU 瓶颈。

## 4. 文档读取顺序

1. [Swift 原生架构与性能决策](research/swift-native-architecture.md)：最新模块选型、源码成本观察、并发/C ABI 边界和测量方案。
2. [任务拆解与验收标准](research/macos-roadmap.md)：P0–P5、已完成检查点及下一阶段工作。
3. [完整可行性分析](research/macos-feasibility.md)：Conky 架构、主题分类、Stats 采集映射、构建/探针证据与局限。
4. [README](README.md)：项目入口。

主项目文档已更新为 Swift 核心方案；上游参考目录中的旧 research/ 文档较早，后续以 ConkyMac 内文档为准。

## 5. 已验证结果及其范围

### Conky 上游无图形版本

- 本机 Darwin arm64 编译成功，实际包含 Darwin Objective-C++ 采集代码。
- CTest **39/39 通过**，仅对应这次开启的编译功能。
- 现代 Lua 配置、旧配置自动转换、独立 Lua 函数运行成功。
- 宿主只读烟测：CPU、网络、文件系统、uptime、进程 CPU/内存有输出，无此前沙箱权限错误。
- CPU 频率持续为 0；内存百分比口径与活动监视器尚未校准。
- X11/Wayland、ncurses、i18n、WLAN 关闭；**没有验证 GUI/Cairo 或主题视觉效果**。

### Stats 方法的普通用户探针

- UID 501，无 sudo/helper：直接用 `SMC/smc.swift` 读到 CPU/GPU 温度，风扇数量 FNum=2。
- F0Ac/F1Ac 没有返回值。该类把部分全零数据解释为 nil；不能确定为风扇停转或映射问题，RPM 尚未验证。
- IOReport Energy Model 采样可访问；CPU Stats 通道可枚举。**没有完成 E/P 核频率计算**。
- 编译 Stats 的 HID reader 后返回 21 个温度传感器条目。
- 短时功耗差分中 GPU 有非零值、CPU 为 0；只是采样路径可用的证据，不能宣称完整功耗测量准确。
- 仅阅读/提取验证了部分方法；没有编译或安装完整 Stats 应用，也没有控制风扇。

### Swift 与 Lua

- Swift 6.4，`swiftc -O -j 16` 编译并直接链接现有 Lua C 库成功。
- Swift 传入固定指标 table，Lua 返回：`SWIFT_LUA_OK cpu=42 memory=25`。
- `lua_pcallk` 捕获预期脚本错误：`LUA_ERROR_BOUNDARY_OK status=2`。
- 本机 Lua 5.5.1 的 luaL_openlibs 是函数宏，使用薄 C inline 包装后导入 Swift。
- 这只证明宿主边界，不包含 conky_parse、Cairo 绘图、实际系统快照、多主题或原生窗口。
- Instruments 的 Time Profiler、Allocations、Leaks、Power Profiler、Swift Concurrency 等模板可列举；**没有录制原生应用 profile**。

## 6. 已观察的成本与实现边界

源码观察，尚未做真实主题热点排序：

- Conky Darwin top 为每进程重复采集整机 CPU，派发两个异步块并轮询等待；CPU sample 分配/全局句柄所有权也值得复核。
- 回调有去重复，但每回调持久线程和 wait=true 等待不宜直接成为新应用调度。
- conky_parse 每次调用分配、构造表达式对象、求值、释放；重复表达式可改为有界解析缓存与快照绑定。
- 文本描边会做八次偏移绘制再画前景；原生主题可缓存静态布局与资源。
- Swift Task 会继承 actor 隔离；在 MainActor 内包 Task 不会自动把同步 IOKit/Lua 工作移出主线程。
- Lua state/画布串行访问；受保护调用及可能 longjmp 的 C 路径要正确包装，避免跨 Swift frame。
- 当前 Conky 有 conky_surface()，旧 Xlib 画布可迁移；引擎提供的 surface 不能沿用旧脚本的自建画布销毁逻辑，也不能跨帧缓存。

## 7. 临时目录与可复用资产

检查时以下资产仍存在，但 /private/tmp 可能被清理；不存在时按文档重建，不把临时目录当正式代码库。

```text
/private/tmp/conky-feasibility-20261014/
  tools/bin/cmake             # 隔离 venv 的 CMake 4.4.4
  build/src/conky             # 已验证的 Debug 无图形上游二进制
  build/tests/test-conky
  build.log / ctest.log
  smoke.conf / smoke.lua / legacy.conf / top.conf
  host-smoke.stdout.log / host-smoke.stderr.log
  host-top.stdout.log / host-top.stderr.log
  stats/                     # 参考源码
  sensor-probe/              # SMC Swift 与 IOReport/HID Objective-C 探针源码/二进制
  smc-results.log / ioreport-results.log
  swift-lua-probe/           # C module map/header、Swift 入口、可执行 probe
  swift-module-cache/
  air-clock.lua / rings.lua  # 社区源码样本，尚未作为可分发主题引入
```

两个社区样本是 fxthomas/conky 的 clock.lua 与 mptrsen/dotfiles 的 .conky/rings.lua。它们不是最终选定主题；GitHub 元数据未声明许可证，不自动取得资源再分发许可。

可直接复用现有上游构建检查：

```sh
/private/tmp/conky-feasibility-20261014/tools/bin/cmake --build /private/tmp/conky-feasibility-20261014/build --parallel 16
/private/tmp/conky-feasibility-20261014/tools/bin/ctest --test-dir /private/tmp/conky-feasibility-20261014/build --output-on-failure
```

## 8. 环境与操作范围

- 完整 Xcode 已选中，本次查到 Swift 6.4、AppleClang 21、macOS SDK 27，系统 macOS 27.0.1。
- 复用了已有 Homebrew Lua 5.5.1、pkg-config 与系统 Make；只在临时 venv 添加 CMake。未修改全局依赖或配置。
- 调研时 pkg-config 缺少 Cairo、FreeType、Fontconfig、HarfBuzz、Imlib2、librsvg、X11/Xft。后续先复核，再按需要准备；新增全局依赖需明确授权。
- 原生主题可先使用已有 Apple 框架推进；Cairo 接入另行准备依赖。不要运行上游 mise install 顺带下载整套开发工具。
- sysctl/进程/uptime/IOKit 与 Instruments 部分操作受当前执行沙箱影响；宿主只读验证成功。执行沙箱与最终应用 App Sandbox 是不同概念。
- 本次会话可写根目录是上游 conky，新项目 conkymac 的文档写入使用了受审查的沙箱外执行。新会话应直接打开 conkymac，并遵守其实际权限与当前指令。
- 许可证：Conky GPLv3-or-later/部分 BSD；Stats MIT。主题、图片、字体另查许可。

## 9. 下一步建议

当前可行性调研已完成；以下是建议后续工作，并非已完成实现：

1. 选择三种喜欢的代表主题：文字/时钟、Lua 圆环/钟表、图片混合。具体主题、最低支持 macOS、Lua 固定版本仍待确定。
2. 先完成 Swift 原生应用窗口、共享指标快照和一个原生文字/圆环主题。
3. 接通一个真实 Lua/Cairo 主题；保留外观算法，替换画布、数据源和路径。
4. 对固定输入做视觉对照，对 Release 构建测 CPU、内存、采集次数、绘制 p95、线程与唤醒；分别统计两种渲染路径。
5. 从实际主题迁移提炼有限转换规则，再拓展桌面行为、多主题和打包。

重开会话可使用：

> 请先读取 /Users/chenxin/Local/conkymac/CHECKPOINT.md 和其中列出的最新架构/任务文档，然后接续 ConkyMac 项目。目标是高性能原生 macOS 程序，并能通过转换和适配复用 Conky 主题。
