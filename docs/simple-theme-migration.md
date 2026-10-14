# Simple-Conky-theme 原生迁移记录

日期：2026-10-14。用户指定 [Abs-30/Simple-Conky-theme](https://github.com/Abs-30/Simple-Conky-theme) 为首个原生原型的外观参考。本文件确定首轮范围和验收依据；它不是功能完成或测试通过的记录。

实现沿用 [Swift 原生架构](../research/swift-native-architecture.md) 的共享采集、不可变快照与 AppKit 原生绘制方案，对应 [任务路线图](../research/macos-roadmap.md) 的 P0 和 P1 原生部分。本主题以文字、进度条和 CPU 历史图为主，首轮无需 Lua/Cairo；复杂 Lua 主题适配仍是后续独立工作。

## 1. 参考版本与来源

参考仓库固定在提交 `5895d2e8b5e726f25db88826df252fad81bea3ed`，本次仅阅读配置、README 和截图，没有运行上游安装、启动或采集脚本。

| 资料 | 用途 |
| --- | --- |
| [README](https://github.com/Abs-30/Simple-Conky-theme/blob/5895d2e8b5e726f25db88826df252fad81bea3ed/README.md) | 声明面向 Fedora 42 / GNOME，列出字体、天气、NVIDIA 与日历依赖 |
| [Screenshot4.png](https://github.com/Abs-30/Simple-Conky-theme/blob/5895d2e8b5e726f25db88826df252fad81bea3ed/Screenshot4.png) | README 当前展示的视觉参考：左侧窄栏、白灰文字、紫色 CPU 历史图、细进度条 |
| [Simple-Conky-theme.conf](https://github.com/Abs-30/Simple-Conky-theme/blob/5895d2e8b5e726f25db88826df252fad81bea3ed/Simple-Conky-theme/Simple-Conky-theme.conf) | 部件顺序、布局参数、指标与外部命令清单 |
| [Simple-Conky-theme-NoGPU.conf](https://github.com/Abs-30/Simple-Conky-theme/blob/5895d2e8b5e726f25db88826df252fad81bea3ed/Simple-Conky-theme/Simple-Conky-theme-NoGPU.conf) | 删除 NVIDIA 部件的变体；仍依赖 Linux 温度、电池和网络路径 |
| [gcalendar.conf](https://github.com/Abs-30/Simple-Conky-theme/blob/5895d2e8b5e726f25db88826df252fad81bea3ed/Simple-Conky-theme/gcalendar.conf) | 右上角独立日历窗口，调用 `gcalcli` |

上游 README 还列出 [CaffeineOnIce 的基础主题](https://gist.github.com/CaffeineOnIce/4da72d18e20c9869895b31540e46b242) 和 [Malformed Blog](https://malformed-blog.blogspot.com/2025/02/how-to-apply-theme.html)。本次没有继续核验这些二级来源的完整内容与授权。

### 截图与配置的差异

截图和当前配置并非逐像素一致的同一基线：

- `Screenshot4.png` 中星期、日期、时钟靠左；当前配置三行均使用 `$alignr`。首轮以截图的左对齐为视觉目标。
- 配置 `alignment = 'top_left'`、`gap_x = 35`、`gap_y = 5`、`maximum_width = 260`；截图中左边距约 25 像素。260 可作为内容宽度起点，截图像素不能直接视作 macOS points 或 Retina 像素。
- 截图进程表可见三行，当前配置列出五行；该部件留待后续，不以截图行数推断配置行为。
- 右侧日历来自另一份配置，不属于左侧 sidebar 的同一窗口。桌面壁纸、面板、桌面文件图标也不属于首轮主题绘制内容。

因此用截图确定视觉层级和对齐，用配置识别指标、颜色与依赖。替换字体和删去后续部件后，首轮高度与完整 Linux 截图会不同；不得据此声称完成原主题的像素级复刻。

## 2. 资源与许可边界

在上述提交中没有找到覆盖整个主题仓库的根目录 LICENSE/COPYING。`fonts/NerdFontsSymbolsOnly/LICENSE` 是带 Ryan L McIntyre 版权告知的 MIT 文本，仅凭这个子目录文件不能推定主题配置、脚本、截图、壁纸和其他字体都获得相同许可。

首轮自行编写 Swift 布局和绘制代码，记录外观来源，不复制或打包上游配置、脚本、截图、壁纸及字体文件。正文优先使用系统已有的 `IBMPlexMono`，缺失时回退到 Menlo，不安装字体；图标使用系统 SF Symbols。字体回退和图标替换会产生字宽、基线和图形形状差异，需要在视觉检查中接受并记录。没有启动服务或执行任何上游脚本的必要。

如果后续要直接复用或随应用分发第三方文件，应先逐项确认许可并保留相应告知；公开可访问本身不能作为再分发授权。

## 3. 首轮原生 sidebar 范围

目标为单个透明、无边框的桌面监控窗口：白色主要数值、灰色标签、细条形图和淡紫色 CPU 历史图。系统字体和图标在主题中统一定义；普通采集以 1 Hz 起步，容量与电池等读数可使用更低频率，所有部件共享采集快照。

| 部件 | 原主题参考 | 首轮原生行为与边界 |
| --- | --- | --- |
| 星期、日期、时钟 | `%A`、`%d %B %Y`、`%H:%M` | 本地时间，保留大号时钟和星期/日期层级；固定输入渲染使用固定时区与时间 |
| 系统信息 | `/etc/fedora-release` | 显示 macOS 系统信息，替换 Fedora 标签 |
| 电池 | `/sys/class/power_supply/BAT0/status`、`battery_percent`、`battery_bar` | 原生电源读数、供电状态与进度条；无电池或读取不可用时明确显示不可用 |
| Uptime | `uptime -s` | 系统运行时长，保持紧凑右对齐数值 |
| CPU | `cpu`、`cpugraph cpu0 25,260` | 整机归一化使用率与有界历史图；首个差分样本没有基线时不伪造 0% |
| Frequency / Temperature | `freq_g`、`sensors` | 保留 `FREQUENCY`、`TEMPERATURE` 两行，显示 `N/A`；传感器采集与数值验证留待后续 |
| RAM | `mem`、`memmax`、`membar` | 已用/总量与进度条；记录 macOS 内存计算口径，不能直接沿用 Linux `no_buffers` 的含义 |
| Storage | `fs_used /`、`fs_size /`、`fs_bar` | 选定卷的已用/总量与进度条；核对 APFS 容量含义，不能把数值差异当成排版问题 |
| Network | 固定接口 `wlp0s20f3` 的速率和累计流量 | 原生接口计数及真实时间差分；显示所选主接口、上传/下载速率和 `SESSION UP/DOWN`，不硬编码 Linux 接口名 |

`SESSION UP/DOWN` 定义为应用本次运行期间所选主接口的有效采样增量累计。接口切换、读取失败、窗口隐藏或系统休眠时保留已经累计的部分；恢复时重建差分基线，暂停区间的流量不回补。计数回退或采样间隔无效时同样重建基线，不把异常差值加入累计量。首轮用接口名称表达数据来源；Wi-Fi SSID 不通过原主题 Shell 脚本读取，也不为此扩展授权或权限范围。

指标必须保留单位、采样时间和可用性。无数据、未建立差分基线和过期数据不能显示为看似有效的零值。原生渲染与实时采集分离，使同一布局可以用固定快照进行视觉检查。

## 4. 后续部件与迁移工作

| 部件 | 上游依赖 | 后续处理 |
| --- | --- | --- |
| 天气 | OpenWeatherMap、脚本、缓存 JSON、`jq`、天气图标字体 | 单独设计原生网络请求、城市设置、凭据与缓存；首轮不请求天气服务、不要求 API key |
| 日历 | `gcalcli`、Google Calendar、独立窗口 | 另行确定数据来源、授权和原生布局；首轮不读取用户日历 |
| CPU 温度 | `sensors` 与固定 Core 0–3 文本解析 | 参考已有 SMC/HID 探针，按硬件确认传感器含义、无效值及恢复行为 |
| CPU 频率 | `freq_g` | Apple Silicon 的 E/P 核频率需完成驻留差分与频点表计算，不能展示未验证的固定值 |
| GPU 名称、温度、功耗、显存、频率 | 多次调用 `nvidia-smi` | 为 Apple GPU 分别定义可用指标与统一内存语义，不照搬 NVIDIA 的 VRAM/频率栏 |
| 进程榜 | `top name`、`top pid` | 集中、有界地采样和排序；避免每个进程重复读取整机 CPU |
| Wi-Fi SSID | 上游 `ssid` 脚本 | 按 macOS 能力和实际权限另行处理；缺失时仍保留基本网络统计 |

原型保留 `FREQUENCY`、`TEMPERATURE` 两行并显示 `N/A`，明确表明读数尚未接入；本节其他未实现部件暂不进入首轮界面。已有 Conky/Stats 探针结果只证明部分底层路径可用，不构成它们已经接入 ConkyMac 的证据。

## 5. 验收与记录要求

以下都是待执行的完成标准，本文件不勾选通过：

1. **固定输入画面**：固定时间、时区、CPU 历史、容量、电池和网络快照，生成原生画面；检查左对齐时钟、窄栏层级、标签/数值间距、文字裁切、图表颜色及 Retina 清晰度。与 `Screenshot4.png` 对照时注明系统字体、图标替换和删去部件造成的差异。
2. **真实数据链路**：以真实系统读数连续更新，核对百分比、单位、内存/容量口径、差分首样本、接口切换和无电池/无数据行为。构建成功或固定快照能画出界面不能代替这一步。
3. **桌面行为**：实际检查窗口位置、透明合成、鼠标穿透、普通窗口层级、退出后的进程清理；Spaces、显示桌面、全屏、Stage Manager、多屏及睡眠恢复分项记录，未执行的项保持未验证。
4. **资源基线**：使用 Release 构建，记录机器、系统、刷新周期、采样次数、应用 CPU、常驻内存与运行时长；后续补绘制耗时和 Instruments profile。未测量前不作高性能达标声明。
5. **版本与审查**：原生实现、指标采集和迁移文档在隔离分支/worktree 开发；合并前进行 code review，记录实际运行的检查、问题修复与仍未覆盖的行为，再更新项目 checkpoint。

应用的实际完成情况及验证结果应写入 [CHECKPOINT.md](../CHECKPOINT.md)，保持这里的来源、迁移范围与验收依据可追溯。
