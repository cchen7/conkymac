# 原生侧栏原型：实现、审查与验证

日期：2026-10-14。状态：原型已提交；宿主 GUI、采样与 120 秒性能基线已实测（见“宿主验证”）。不是 P1/P2 完成报告。

## 实现范围

- Swift 6 package：`ConkyMacCore` 负责不可变快照、采集和调度，`ConkyMac` 负责 AppKit 窗口和 CoreText/原生图形。
- 260 points 内容宽度，300 × 790 points 画布；时钟/日期左对齐，参考 Screenshot4；字体与图标替换、删除天气等部件使其不等同于完整 Linux 主题。
- 1 Hz 单一 DispatchSourceTimer，每轮单次 CPU/内存/网络采集；容量/电池 30 秒缓存。主线程只接收快照和绘制。
- 桌面透明、鼠标穿透、桌面图标下方层级；预览和菜单栏操作路径已实现，**实际窗口行为尚未通过宿主验证**。
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

### 仍未验证

菜单栏 Hide/Show/Preview 切换的实际点击（需辅助功能授权，未执行）；真实休眠/唤醒、Spaces、多屏、Stage Manager；Instruments profile；长时间（小时级）内存曲线；macOS 14 实机。Quit 路径仅经 `--smoke` 结束时的 `NSApp.terminate` 验证。

## 恢复前原定顺序（已执行 1–3 的可自动部分）

1. 确认 Git/权限服务恢复；将文档 worktree 的单文件提交并 cherry-pick 到功能分支。
2. 宿主执行 `zsh scripts/validate.sh --gui`；若 bundle 仍异常，优先调查它与独立二进制的差异。
3. 截图确认预览/桌面透明、层级、鼠标穿透、Hide/Show/Quit 和进程清理；再做明确时长的 Release 性能基线。
4. 更新实际验证结果，提交原型和记录；确认全部检查前不合并 main、不标记 P1/P2 完成。

没有 commit/push 新实现，没有安装应用、服务或全局依赖，也没有操作天气/日历账户。
