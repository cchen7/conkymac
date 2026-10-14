# 当前实施检查点

2026-10-14：用户选择 https://github.com/Abs-30/Simple-Conky-theme 作为参考。

本轮交付原生侧栏原型：Swift/AppKit 透明桌面窗口，1 Hz 后台共享快照，时钟、CPU 历史、RAM、磁盘、电池、uptime 和网络。使用系统等宽字体和 SF Symbols；不运行上游安装脚本，不分发上游资源。macOS 14 暂作为编译最低版本，仅在本机运行验证。

- [x] 阅读 CHECKPOINT 及架构、任务、可行性文档，核对 Git 状态。
- [x] 读取参考主题配置和 Screenshot4，记录外观及平台差异。
- [x] 实现核心采集、原生渲染、窗口和退出路径；GUI 实际行为待验证。
- [x] Release 构建，4 项核心测试验证差分、缺失数据、历史有界行为。
- [x] 固定输入 1×/2×画面检查，同机重复渲染哈希一致。
- [x] 两轮 subagent code review，修复休眠时钟、网络累计清零、图表最新列裁切。
- [x] 宿主真实采样和窗口运行验证：采样全项通过，bundle 预览/桌面模式退出 0、透明、鼠标穿透、无残留；exit 134 仅出现在执行沙箱。
- [x] 120 秒 Release 性能基线；修复宿主验证发现的网络计数器 32 位回绕问题，测试 5/5。
- [x] 更新 README、路线图和 CHECKPOINT，保留未完成边界。
- [x] 提交实现和整合文档（e33b196、dcbdfa2）。
- [x] 双显示器：每屏右上角一个面板，主屏避让桌面图标；“显示桌面”手势可见、Preview 菜单由用户实机确认。
- [x] 进程榜（ps，每 3 秒）、温度（SMC 簇级最热）、频率（IOReport + DVFS）、逐核与 P/E 簇占用、负载、Swap、GPU 温度。
- [x] Lua/Cairo 主题：内置 Lua 5.4.9、CoreGraphics 实现的 cairo 子集、Theme 菜单；只接受文本源码，时间预算不可被吞掉。
- [x] 内置主题 Minimalis 与默认的 Simple Plus（用户指定的拼合样式）。
- [x] 每阶段 code review 与修复；验证记录见 `docs/native-prototype-validation.md`。
- [ ] 手动验证菜单栏 Hide/Show/Quit 与 Theme 切换、Spaces 切换、显示器热插拔、休眠/唤醒；Instruments profile。
- [ ] 用户确认 Simple Plus 实机效果；温度/频率与活动监视器或 powermetrics 对照。

完成标准：无全局依赖安装；单轮单次系统采样；首次差分无伪造 0；不可用值显示 N/A；1 Hz 连续更新；固定输入渲染可复现；启动/退出无遗留子进程。性能记录只能表述实测范围，不提前宣称 P1/P2 全部完成。

后续另做：温度/频率/GPU、进程排行、天气/日历、Lua/Cairo、完整主题转换和 Spaces/多屏矩阵。

详见 `docs/native-prototype-validation.md`。
