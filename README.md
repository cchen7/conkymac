# ConkyMac

在 macOS 上实现原生桌面监控，并通过配置转换和脚本适配复用 Conky 生态中的外观主题。

目标是高性能原生 macOS 程序。当前处于架构调研阶段，尚未实现原生应用。推荐以 Swift 构建应用、AppKit 窗口、共享采集与调度、主题模型和原生渲染；参考 Stats 的采集方法，保留 Lua/Cairo 作为复杂主题适配层。Conky 主要作为语法与主题行为参考，实际复用范围由代表主题和性能验证决定。

## 调研与计划

- [会话交接 checkpoint](CHECKPOINT.md)
- [可行性分析](research/macos-feasibility.md)
- [任务拆解与验收标准](research/macos-roadmap.md)
- [Swift 原生架构与性能决策](research/swift-native-architecture.md)

已完成的 39 项测试及配置烟测属于 Conky 上游的无图形版本。传感器探针验证了本机上的部分 Stats 采集方法；这些结果不代表 ConkyMac 已完成显示、主题兼容或应用运行验证。

下一步是选择代表主题，先完成 Swift 原生窗口、共享指标快照与一个原生主题；随后接通一个真实 Lua/Cairo 主题，分别建立视觉和性能基线。

## 参考项目

- [Conky](https://github.com/brndnmtthws/conky)：模板、配置、绘图与主题生态；GPLv3-or-later，部分继承代码为 BSD。
- [Stats](https://github.com/exelban/stats)：macOS 与 Apple Silicon 采集实现；MIT。

后续复用代码与主题资源时保留相应许可和版权告知。
