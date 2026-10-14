# ConkyMac

在 macOS 上实现原生桌面监控，并通过配置转换和脚本适配复用 Conky 生态中的外观主题。

目标是高性能原生 macOS 程序。现有 Swift/AppKit 侧栏原型以用户指定的 [Simple-Conky-theme](https://github.com/Abs-30/Simple-Conky-theme) 为外观参考：时钟、CPU 历史图、内存、磁盘、电池、运行时间与网络。共享采集在后台串行队列以 1 Hz 运行；磁盘容量和电池每 30 秒更新。未接通的频率、温度显示 N/A。

**当前状态**：原型已提交；Release 构建、5 项核心测试、宿主采样、预览/桌面模式 GUI 烟测和 120 秒性能基线已实测通过。菜单切换、休眠、Spaces/多屏仍待手动验证。详见 [CHECKPOINT.md](CHECKPOINT.md) 和 [验证记录](docs/native-prototype-validation.md)。

## 构建与运行

需要现有 Xcode/Swift 6 工具链。编译最低系统暂设 macOS 14，尚未在 macOS 14 实机验证。无第三方包依赖、无需安装字体，构建产物默认放在 `/private/tmp/conkymac-build`。

```sh
zsh scripts/build-app.sh
open /private/tmp/conkymac-build/ConkyMac.app --args --preview
zsh scripts/validate.sh --gui
```

直接启动应用默认进入透明桌面模式：每块显示器右上角各一个面板，出现在所有 Spaces，触控板“显示桌面”手势时保持可见；主显示器额外左移 120pt 避开 Finder 桌面图标列。菜单栏提供 Preview、Show on Desktop、Hide 和 Quit。关闭预览窗口只隐藏并停止采集；Quit 才退出。当前会话没有安装或常驻运行该应用。

命令行选项：`--probe 5` 输出真实样本，`--render /tmp/simple.png` 输出固定输入 PNG，`--scale 1|2` 指定像素倍率，`--smoke 15` 运行 GUI 后自动退出，`--icon-margin N` 调整主显示器为桌面图标预留的右边距（0–600pt，默认 120）。`--interface en0` 可指定网络接口；默认使用系统主接口，可能是 VPN。`SESSION UP/DOWN` 只累计应用有效采样区间的所选接口流量，暂停区间不补算。

`CONKYMAC_BUILD_DIR` 可指定隔离构建目录。`validate.sh` 遇到指标不可用会以非零状态结束，不能将沙箱里的部分成功当成完整通过。Lua/Cairo、天气、日历、GPU、进程榜、主题转换器和完整桌面行为矩阵仍待实现。

## 调研与计划

- [会话交接 checkpoint](CHECKPOINT.md)
- [可行性分析](research/macos-feasibility.md)
- [任务拆解与验收标准](research/macos-roadmap.md)
- [Swift 原生架构与性能决策](research/swift-native-architecture.md)

上游 39 项 CTest 与本项目 4 项 Swift 测试是两套独立结果。Stats 探针并不代表传感器已接入本应用。当前还没有原生应用 CPU/RSS/Instruments 性能基线，也未完成原主题全部部件或逐像素迁移验收。

## 参考项目

- [Conky](https://github.com/brndnmtthws/conky)：模板、配置、绘图与主题生态；GPLv3-or-later，部分继承代码为 BSD。
- [Stats](https://github.com/exelban/stats)：macOS 与 Apple Silicon 采集实现；MIT。

后续复用代码与主题资源时保留相应许可和版权告知。
