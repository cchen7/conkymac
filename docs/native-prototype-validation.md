# 原生侧栏原型：实现、审查与验证

日期：2026-10-14。状态：原型已提交；宿主 GUI、采样与 120 秒性能基线已实测（见“宿主验证”）。不是 P1/P2 完成报告。

## 实现范围

- Swift 6 package：`ConkyMacCore` 负责不可变快照、采集和调度，`ConkyMac` 负责 AppKit 窗口和 CoreText/原生图形。
- 260 points 内容宽度，300 × 790 points 画布；时钟/日期左对齐，参考 Screenshot4；字体与图标替换、删除天气等部件使其不等同于完整 Linux 主题。
- 1 Hz 单一 DispatchSourceTimer，每轮单次 CPU/内存/网络采集；容量/电池 30 秒缓存。主线程只接收快照和绘制。
- 桌面透明、鼠标穿透、桌面图标下方层级；每块显示器一个面板（右上角，主显示器额外让出桌面图标列），屏幕参数变化时重建；透明模式下文字/图形加深色阴影。预览为主显示器上的单个普通窗口。
- Hide/sleep 停采集，恢复时重建差分基线和慢缓存；generation 丢弃过期主线程回调。这些路径已有代码审查，真实休眠/唤醒尚未测试。
- CPU 历史 120 点、文字布局缓存上限 192、绘制计时记录上限 600；不建立无界历史，不为每个控件分别采样。

## 指标口径

| 指标 | 来源 / 单位 / 边界 |
| --- | --- |
| CPU | `host_statistics(HOST_CPU_LOAD_INFO)` 四类 tick 差分；整机归一化 0...1；首样本/重置无值 |
| RAM | `host_statistics64`；Stats 公式 active + inactive + speculative + wired + compressed - purgeable - external；以字节保存，不宣称与活动监视器已校准 |
| Storage | `/System/Volumes/Data` 文件系统 total/free；已用为 total-free；APFS 共享容量/可清除空间与 Finder 口径可能不同 |
| Battery | IOPowerSources 内置电池；无电池与读取失败分别表达；30 秒更新 |
| Uptime | `kern.boottime` 到当前墙钟的时长，秒；本执行沙箱中不可访问时为 nil |
| Network | 系统 PrimaryInterface，`NET_RT_IFLIST2` 字节计数；本机 macOS 27 对本进程返回值截为 32 位并按 1 KiB 取整（见宿主验证），按 32 位回绕处理；不重复累加物理与 VPN 接口 |
| Network rates | `mach_continuous_time` 包含休眠的单调时间差；小幅向后跳视为 32 位回绕；接口变化、其他回退、失败或间隔 >5 秒重新建立基线 |
| Session totals | 本应用有效采样区间增量之和；跨基线重置保留，暂停流量不回补；没有无限接口历史表 |

快照有采样时间、可用性、错误摘要和采集耗时；慢指标保留自身 sampledAt。频率和温度固定显示 N/A，尚无有效传感器源；天气、日历、GPU、进程榜暂不绘制。

## Code review

用户要求并行工作后，文档代理在独立 worktree 编写迁移记录；另一代理只读审查采集、并发、界面与脚本。主代理整合修复并复核。

| 发现 | 修复 / 验证 |
| --- | --- |
| systemUptime 不包含休眠，不能作为跨睡眠差分/缓存时钟 | 改为 `mach_continuous_time`；显示 uptime 单独读 boot time；唤醒清基线及慢缓存 |
| 读取失败或重新建立网络基线会清零 session totals | 分离累计量与 baseline；复用 collector；测试覆盖失败、长间隔、换接口和显式 reset 后累计量保留 |
| CPU 图最新一列在裁剪矩形外 | 使用内缩后的 plot rect 和半点边距计算所有列；重新生成并检查 1×/2×画面 |

另将固定输入的 OS 文本放入 fixture，固定模式强制 Menlo，消除这两项主机输入差异。SF Symbols 和系统文本栅格化仍受 macOS 版本影响。

## 实际执行结果

机器：本机 Apple Silicon，Swift 6.4/macOS SDK 27；构建目标 arm64-apple-macos14.0，16 路并行。

| 检查 | 结果 |
| --- | --- |
| `zsh scripts/build-app.sh` | Release 成功；增量复用；临时 `.app` 已生成 |
| `zsh scripts/swift.sh test -c release` | Swift Testing 4/4 通过；XCTest 的 0 tests 不是遗漏，测试使用 Swift Testing |
| CPU 测试 | 整机差分、零变化、回退、UInt32 wrap |
| Network 测试 | 首样本、实际时间差分、切换接口、回退、长间隔、失败、reset 和 session 累计保留 |
| History 测试 | 保留缺口、顺序、旧值淘汰；10,000 次更新容量保持 3（测试容量） |
| 独立二进制 `--render` | 最终版 300×790 与 600×1580 PNG 成功，并已查看；固定 2×连跑两次 SHA-256 相同 |
| `.app` 的签名与 plist | `codesign --verify --strict`、`plutil -lint` 成功；仅本地 ad-hoc 签名，不是分发签名/公证 |
| Shell 脚本语法 | `zsh -n` 通过；完整 validate.sh 尚未端到端通过 |
| 沙箱内 `--probe 5` | CPU/RAM/Storage/Battery/Network 有真实输出；首样本不伪造 CPU/网络速率；慢缓存复用 |
| `check-samples.py` | 其他断言通过，报告 `SAMPLE_CHECK_PARTIAL: Uptime: kern.boottime unavailable`，退出码 2；不算完整采样验证通过 |
| bundle 内 `--render` 与 GUI `--preview --smoke` | 沙箱内退出码 134，无标准错误详情；独立二进制离屏成功。需在宿主区分沙箱、AppKit 与打包问题，尚不能归因或宣称运行成功 |
| 宿主采样、GUI、性能 | 权限升级未执行：自动审批服务内部解密错误；未录制 Instruments、未测 CPU/RSS/唤醒或绘制 p95 |

最终 2× PNG SHA-256：`99df9bb5b2281fcbea55c26e9b986022e88cb3047766054c181c473cb2049b60`。

证据保留在 `/private/tmp/conkymac-validation-20261014/`：`build-final.log`、`tests-final.log`、`probe-final-sandbox.jsonl`、`simple-final-1x.png`、`simple-final-2x.png`、`simple-repeat-2x.png`。临时目录可能被系统清理，以上结果摘要与源码才是持久交付。

## 宿主验证（审批恢复后，2026-10-14）

均在本机宿主（非执行沙箱）实际运行，产物在 `/private/tmp/conkymac-validation-host/`。

| 检查 | 结果 |
| --- | --- |
| `zsh scripts/validate.sh` | 测试、构建、1×/2× 渲染通过；`--probe 5` 为 `SAMPLE_CHECK_OK samples=5 interface=utun8`，uptime 可读 |
| bundle `--preview --smoke 15` | 退出 0，`SAMPLE_CHECK_OK samples=15`，无残留进程。此前 exit 134 只在执行沙箱出现 |
| bundle 桌面模式 `--smoke 12` | 退出 0；`mouse_passthrough=true level=-2147483604`（桌面图标层 −1）；无残留进程 |
| 桌面窗口截图 | `screencapture -l` 抓取 300×790 pt 窗口，背景透明（alpha），合成到深色底查看：时钟、实时 CPU/RAM/Storage/Battery/Uptime/Network 正常绘制 |
| 120 秒性能基线（桌面模式，`--smoke 120`，含逐样本 JSON 输出） | 120/120 样本校验通过；进程 CPU 时间 0.71 s（含启动，约 0.6% 单核）；`ps` %cpu 均值 0.23%、峰值 1.4%；RSS 82.8→83.8 MiB；线程 ≤17；绘制 p95 2.49 ms；采集 p50/p95/max 0.66/1.03/1.67 ms |

### 发现：网络计数器被截断

本机 macOS 27.0.1 上，`NET_RT_IFLIST2` 与 `getifaddrs` 对本进程返回相同值：`⌊(真实 64 位计数 mod 2³²) / 1024⌋ × 1024`。例：utun8 netstat 24,781,032,021 → 本进程 3,306,194,944（逐位吻合）。20 MB 下载期间增量与 netstat 相差 197 字节，即只有取整误差、无漏计。`netstat` 能读到精确 64 位值；原因（权限/授权）未查明。

影响：每 4 GiB 流量回绕一次，旧逻辑将其当作回退并丢弃一个区间；低速率以 1 KiB 为步进。修复：`NetworkTracker.delta` 仅当旧值 ≤ UInt32.max、且回绕增量 ≤ min(Int32.max, 1.25 GB/s × 间隔)（10 Gbit/s 上限）时视为 32 位回绕，其余仍重建基线。速率上限来自 code review：截断计数下，旧值 ≥2 GiB 时的接口计数重置与回绕不可区分，可能凭空累加最多 2 GiB；漏判回绕只丢一个区间，代价更小。接口同名重置在 macOS 上是否发生未验证。新增测试，Swift Testing **5/5 通过**。1 KiB 粒度未处理，仅记录。

### 双显示器与“显示桌面”（2026-10-14，用户实机确认）

环境：DELL U3223QE（主，2560×1440 pt）+ 内置 Retina（1512×982 pt），“显示器具有单独的空间”为默认开启。

| 检查 | 结果 |
| --- | --- |
| 每屏窗口 | `GUI_SUMMARY windows=2 frames=2125,605;-315,602`：主屏距右缘 135pt（15+120），内置屏 15pt；层级与鼠标穿透同前 |
| 四指张开“显示桌面” | 用户截图并确认：两块面板保持可见，未被推开 |
| 桌面图标 | 初版贴右边与 Finder 图标列重叠（用户截图）；主屏加 120pt 后用户确认不再重叠。Finder 设置：图标 64pt、网格间距 54 |
| 可读性 | 初版亮色壁纸上标签难读；透明模式加阴影（blur 2、黑 0.95）后用户确认清晰。逐图元阴影时绘制 p95 约 4 ms（14 帧）；按审查改为单个透明图层整体投影后 2.78 ms（30 样本/62 帧），外观不变。固定输入渲染 SHA-256 仍为 `99df9bb5…` |
| Preview 菜单 | 用户截图确认预览窗口完整显示 |

自动触发“显示桌面”未成功：从本会话启动 Mission Control 被杀（exit 137），System Events 需辅助功能授权，未申请；以上手势结论来自用户实机操作。

## 进程榜、温度/频率与主题（2026-10-14 晚）

均为宿主实测，机器 Apple M4 Max（12P+4E）、macOS 27.0.1，Release。

### 进程榜

- libproc（`proc_pid_rusage`）对本进程只成功 728/1083 个，354 个 EPERM，包括 WindowServer 等 root 进程。用户选择改用 setuid `/bin/ps -A -o pid=,%cpu=,rss=,state=,comm=`，每 3 秒一次。
- 口径：CPU% 是 ps 的衰减平均（单核 100%），内存是 RSS；一次 ps 同时得到 CPU 榜、内存榜、进程总数和 R 状态数。
- 开销（20 次平均）：本进程约 2 ms，ps 子进程约 25–27 ms，即每 3 秒一次约占单核 0.8–0.9%。`ps -c` 只省约 1 ms 且会截断名称，未采用。Foundation `Process.waitUntilExit` 的墙钟时间是 posix_spawn 的两倍，改用 posix_spawn + poll + waitpid。
- 审查后加固：`LC_ALL=C`（`LC_ALL=de_DE.UTF-8` 下 ps 输出 `0,0`，原先会全部解析失败，已实测修复）、不继承描述符、1.5 s 超时后 SIGKILL 并回收、先关读端再 waitpid、按 pid 稳定排序、按渲染宽度截断名称。

### 温度

- SMC 枚举 3,493 个键约 30 ms，启动后做一次。`Tp1*/Tp2*` 读数为 -4、1.5、0，不是温度（调研代理曾误报）。P 核 `Tp0*/Tpx*` 闲置时钳在 40.00。
- 采用簇级键 `Tpx*`（12）与 `Tex*`（4）的最大值：闲置/8 进程满载/回落时为 48.23/66.62/50.34 °C，与全部约 67 个逐核键的最大值完全相同，读取量约为后者的 1/4。GPU 取 `Tg*`（44 个）最大值。界面显示的是“最热传感器”，不是平均值。
- 空的键发现结果不缓存，偶发失败会在下次采样重试。

### 频率与簇占用

- IOReport `CPU Stats` / `CPU Complex Performance States` 的 `ECPU`、`PCPU`、`PCPU1` 通道，按 pmgr `voltage-states1/5-sram` 表加权驻留时间；本机 E 1020–2592 MHz（7 级）、P 1260–4512 MHz（20 级），单位 kHz。状态数与表长不一致时报 issue 而不给数；表只去掉尾部 0。两个 P 簇按活跃驻留加权合并。
- 采样实测：P 2.4–3.8 GHz、E 1.3–1.5 GHz（轻负载）。P/E 簇占用按 `IODeviceTree:/cpus` 每核 `cluster-type` 计算（本机 cpu0–3 为 E）。
- 开销：频率与温度每 2 秒一次，每次约 10 ms；`--probe 20` 的 CPU 时间由 0.39/0.37 s 增至 0.50/0.47 s，约 +0.5% 单核。每秒采样时为 +0.8%，所以改为 2 秒。

### 主题

- Simple 增加 PROCESSES 区，面板 912pt；Minimalis 340×620pt；Simple Plus（默认）300×812pt。三者都在双屏桌面模式烟测退出 0、无残留进程，绘制 p95 约 2.3–3.7 ms（5–15 样本）。
- 120 秒双屏 Simple（含进程榜）：本进程 CPU 时间 1.75 s（单窗口无阴影基线为 0.71 s；差额主要来自双窗口绘制 246 次与阴影，ps 本进程部分约 0.08 s）、RSS 91–99 MiB、绘制 p95 2.95 ms、采集 p95 59 ms（ps 那一轮的墙钟时间）。
- 固定渲染 SHA-256（2×）：Simple `be97672a…`、Simple Plus `c474572c…`、Minimalis `47ed55b4…`、Lua arcs `a501cfc5…`、本地 rings-clock `a28ddf7d…`；重复渲染逐字节一致。
- Lua/Cairo 分支由子代理在独立 worktree 完成后合并（`0a5a3aa`）。合并后审查发现：时间预算可被脚本的 `pcall` 或 `__gc` 终结器绕过，从而卡死主线程；已修复并加测试（`192b75a`），测试 14 + 8 项通过。

## 与 iStat Menus 的开销对比与优化（2026-10-15）

方法：正常启动的 bundle 与 iStat Menus（菜单栏、helper、root 守护进程）同时运行，用 `ps -o time` 取 180 秒 CPU 时间增量；ConkyMac 的 ps 子进程不计入其进程时间，按次数 × 约 26 ms 另算。单位为单核占比（本机 16 核）。

| 状态 | ConkyMac 本体 | ps 子进程 | iStat 合计 |
| --- | --- | --- | --- |
| 优化前（Simple Plus 双屏，每秒全量重绘与采集） | 2.33% | ≈0.9% | 1.32% |
| 优化后，一块面板可见 | 1.44% | ≈0.5% | 1.32% |

- 采集分项（线程 CPU，30 样本）：频率约 5.5 ms/次、温度约 2.5 ms/次、ps 本进程侧约 4 ms/次、网络约 0.4 ms/次，其余合计 <4 ms/30 s。绘制与合成约占剩余的 18 ms/s。
- 措施：窗口 `occlusionState` 不可见时跳过重绘、可见时立即补画；所有面板都不可见时暂停 ps、SMC、IOReport（CPU/内存/网络照常）；ps 与温度改为 5 秒，频率 2 秒。`--probe 60`（含子进程）由 0.93 s 降到 0.10 s（约 1.55% → 0.17%）。
- 两屏共用一张离屏位图的方案实测更差（4.59%）：CPU 同步栅格化抵不过 AppKit 图层的异步绘制，已撤回。
- 阴影透明层约占 0.3 个百分点（60 秒对照）。不同次测量间有明显波动，以上为单次结果。
- 用户实机确认：Dell 面板平时被遮挡，“显示桌面”时正常刷新。

## 打包与公证（2026-10-15）

- `scripts/package-dmg.sh`：Developer ID Application（Team `S426CS9PRN`）、Hardened Runtime、无 entitlement；app 与 DMG 分别公证并钉票据。团队首次提交排队超过 30 分钟后 Accepted；之后两次提交各在数分钟内 Accepted，日志无 issue。
- 加隔离属性模拟下载后：DMG 与其中 app 的 `spctl` 均为 `accepted, source=Notarized Developer ID`，`stapler validate` 通过，权限 755，挂载运行采样正常。

## M5 兼容修复（0.1.1，2026-10-15）

用户在 M5 MacBook Air 上安装 0.1.0，CPU 温度显示 N/A。原因：温度键只认 M4 Max 上实测的 `Tpx*`/`Tex*`，M5 使用 `Tp00`、`Tp04`…；频率代码也只认 `ECPU`/`PCPU` 与 `voltage-states1/5`，M5 另有 `MCPU` 通道、`voltage-states22` 表，且 device tree 的 `cluster-type` 多出 "M"（Stats 把 M5 分为 efficiency / performance(M) / super(P)）。

- 温度键按芯片代际选择（brand string 解析 `Apple M<n>`），采用 Stats 各代 CPU 列表；M4 为 `Tpx*`/`Tex*` 并上 Stats 的 M4 列表；未知/更新的芯片用 M5 列表加 `Tpx`/`Tex`。每代单独一份，避免别代的键在本代读出 10–120 之间的无关数值而抬高最大值。
- 频率：`ECPU`→states1；`PCPU`→states5；`MCPU`→states22，回退 states5（Stats 对 M6 的做法）；只有“去掉 IDLE/DOWN/OFF 后状态数 = 表长”才采用，否则显示 N/A 并报 issue。M 与 P 簇按活跃驻留合并为界面上的 “P”。`pmgr`、`pmgr-child` 都遍历，后者覆盖前者。核心类型 "M" 计入 P。
- `ConkyMac --sensors` 打印芯片、核心类型、全部 `voltage-states*` 表、IOReport 通道状态与匹配到的表、所有 `T*` 浮点 SMC 键（`*` 为选中的 CPU 键）和最终结果，供在未验证的芯片上取证。
- 审查（采纳）：PCPU 不再回退 states22（Stats 无此配对，可能给出“合理但错误”的数字）；键表按芯片选取；没有 E 核的芯片不再因缺 states1 关闭频率。
- M4 Max 回归：`*` 选中 25 个键，闲置/8 进程满载/冷却时最大值 84.1/67.8/54.5 °C，与只看 `Tpx*`/`Tex*` 的 84.1/67.8/54.3 °C 一致（末项差 0.2 °C 来自两次读取的时间差）；频率与簇占用不变。
- **M5 实机确认**：用户在 M5 MacBook Air（macOS 27.0.1，闲置）上安装 0.1.1，反馈温度与频率正常，并提供了 `--sensors` 输出：
  - 芯片 Apple M5，10 核，`cluster-type` 为 E=6、P=4，**没有 "M"**（基础款 M5 只有 E 与 P；M 类核心只可能出现在 Pro/Max，未验证）。
  - DVFS 表：`voltage-states1-sram` 8 级 972–3048 MHz、`voltage-states5-sram` 19 级 1308–4464 MHz；**没有 `voltage-states22`**。IOReport 只有 `ECPU`（9 个状态，无 DOWN，首项 IDLE）与 `PCPU`（20 个状态），无 `MCPU`、`PCPU1`；去掉 IDLE 后状态数 8/19 等于表长，`frequency issue: none`。也就是说基础款 M5 的频率走的是原有的 states1/states5 路径，`states22`/`MCPU` 分支在这台上没被用到。
  - SMC：2430 个键。选中 11 个 `Tp0*`（`Tp00 Tp04 Tp0C Tp0G Tp0O Tp0R Tp0X Tp0a Tp0p Tp0u Tp0y`，39.8–42.0 °C），结果 CPU 42.0 °C；Stats 列表里的 `Tp08 Tp0K Tp0U Tp0d Tp0g Tp0j Tp0m` 在此机不存在。P 核键在 M5 上能读到低于 40 的值，不像 M4 Max 被钳在 40。GPU 选中 `Tg*` 共 23 个，最大 39.8 °C。
  - 未选中但存在的：`Te04 Te08 Te0C Te0R`（43.9/43.2/42.9/41.7 °C，按 M4 Max 的经验是 E 核传感器，此刻高于被选中的 P 核键）、`Tp12 Tp16 Tp1E`（≈41 °C）。M5 的 E 核较多（6 个），E 核满载时本应用的 CPU 温度可能低于实际最热点。是否纳入 `Te0*` 需要 M5 负载测试（E 核/P 核分别加压，看哪些键随之上升）后再定。
  - 仍无数值对照（活动监视器、`powermetrics`），频率数值本身未提供。M1–M3 与 M4 非 Max 尚无人验证。

### 仍未验证

M1–M3、M4 非 Max 的温度与频率实际读数，以及 M5 的具体数值（仅有“显示正常”的口头确认）；菜单栏 Hide/Show/Quit 与 Theme 切换的实际点击；温度/频率与活动监视器或 `powermetrics` 的对照；Spaces 逐个切换、显示器热插拔/重排、Stage Manager；真实休眠/唤醒；Instruments profile；长时间（小时级）内存曲线；macOS 14 实机。Quit 路径仅经 `--smoke` 结束时的 `NSApp.terminate` 验证。

## 恢复前原定顺序（已执行 1–3 的可自动部分）

1. 确认 Git/权限服务恢复；将文档 worktree 的单文件提交并 cherry-pick 到功能分支。
2. 宿主执行 `zsh scripts/validate.sh --gui`；若 bundle 仍异常，优先调查它与独立二进制的差异。
3. 截图确认预览/桌面透明、层级、鼠标穿透、Hide/Show/Quit 和进程清理；再做明确时长的 Release 性能基线。
4. 更新实际验证结果，提交原型和记录；确认全部检查前不合并 main、不标记 P1/P2 完成。

没有 commit/push 新实现，没有安装应用、服务或全局依赖，也没有操作天气/日历账户。
