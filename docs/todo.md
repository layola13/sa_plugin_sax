# SAX 框架多端与 TUI 渲染支持演进待办清单 (Roadmap & TODO)

本项目基于大方向讨论，旨在为 [sa_plugin_sax](file:///home/vscode/projects/sa_plugins/sa_plugin_sax) 编译器插件新增多目标编译（Web, TUI, Windows, macOS, Android 等）和单一组件源文件（Single-source `.sax`）跨端转换能力，以支持重构 Lite Codex 等高性能终端 AI 代理。

---

## 一、 核心需求与方案概述

### 1. Lite Codex 代理可行性
* **需求**：利用 SA 编译器及插件生态重构 `~/projects/codex`。通过忽略代码高亮、不做可视代码预览，实现一个具备完整功能的轻量级 Lite Codex 命令行代理。
* **方案**：基于已有的 `sa_plugin_http_client` (HTTPS 请求与 SSE 流式读取)、`sa_std/encoding/json` (JSON 解析与流式扫描)、`sa_std/fs` (文件操作) 以及 `sa_std/process` (子进程执行捕获) 搭建纯 SA 的 Agent Loop，不引入多重视口等渲染开销。

### 2. 单一套源码多目标编译 (Single-source compile targets)
* **需求**：只维护一套符合 MUI 标准的 `.sax` 模板代码（使用标准 HTML 标签 `div`/`button` 和 `className` 样式类名），通过配置编译目标直接转换。
* **方案**：在编译器降级阶段（Lowerer），如果是 `tui` 等原生终端目标，编译器自动将 DOM 标签映射为对应的终端布局和输入控件，并解析 `className` 中的特定类名（如 `MuiButton-colorPrimary`），就地翻译为终端 ANSI 颜色和状态属性指令（如 `sa_tui_set_color(node, COLOR_PRIMARY)`）。

### 3. 多平台渲染演进 (Windows, macOS, Android, iOS)
* **需求**：面向未来的操作系统级别 GUI 渲染支持。
* **方案**：
  1. **标准虚拟 UI 树**：`lowerer.zig` 统一编译输出为平台无关 of Virtual UI Node 树及样式属性。
  2. **平台专有运行时渲染器 (Renderer Plugins)**：针对不同端动态加载对应的运行库（如终端的 `libsa_plugin_tui.so`、Windows 的 `sa_plugin_win32.dll`、Android 的 `sa_plugin_android.so`）。
  3. **自绘引擎/控件映射**：通过统一的 Flexbox 布局库计算坐标，采用 WGPU/Canvas 进行自绘（类似 Flutter），或映射到系统原生控件（类似 React Native）。

---

## 二、 阶段性任务清单 (TODO List)

### ⬜ 阶段一：编译器 CLI 命令行扩展 (`sa sax build --target`)
* [ ] 修改 [cli.zig](file:///home/vscode/projects/sa_plugins/sa_plugin_sax/src/sax/cli.zig)，为 `sa sax build` 命令添加 `--target <web|tui>` 参数（默认为 `web`）。
* [ ] 在 `build.zig` 中新增 TUI 目标构建配置，支持输出本地 ELF 目标文件。

### ⬜ 阶段二：TUI Target 下的 Parser 与 Lowerer 适配
* [ ] 扩展 [parser.zig](file:///home/vscode/projects/sa_plugins/sa_plugin_sax/src/sax/parser.zig) 对容器标签及交互标签的降级转换规则。
* [ ] 修改 [lowerer.zig](file:///home/vscode/projects/sa_plugins/sa_plugin_sax/src/sax/lowerer.zig)，使 `--target tui` 下 of DOM 节点（如 `div`, `button`）映射翻译为终端 UI FFI 指令。
* [ ] 实现编译期 `className` 分析模块：
  * [ ] 对静态 `className` 字符串进行分词处理。
  * [ ] 实现 MUI 主题类名映射规则表（`colorPrimary` $\to$ 主色；`disabled` $\to$ 禁用态；`MuiButtonGroup-vertical` $\to$ 垂直布局）。
  * [ ] 在降级汇编代码中自动插入相应的样式和状态初始化指令。

### ⬜ 阶段三：开发运行时 FFI 插件 `sa_plugin_tui`
* [ ] 创建独立的运行库工程：`/home/vscode/projects/sa_plugins/sa_plugin_tui`。
* [ ] 编写 Zig 版本的终端 UI 引擎，实现：
  * [ ] 轻量级 Flexbox/Grid 布局排版算法（计算绝对行列坐标）。
  * [ ] ANSI Escape 终端刷新与重绘缓冲区（Redraw Engine）。
  * [ ] 键盘快捷键绑定与焦点切换（Focus Management）。
  * [ ] 键盘事件（Tab, Enter, Arrow 键）监听与 FFI 事件回调派发。
* [ ] 编写符合 SA-facing ABI 的 `tui.sai` / `tui.sal` 接口描述文件。

### ⬜ 阶段四：跨端标准虚拟 UI 树与多端平台扩展设计
* [ ] 提取并规范通用的 `sa_std/ui` 抽象树 API，使所有平台使用统一的接口（创建节点、追加子树、配置属性）。
* [ ] 调研各平台（Windows, macOS, Android, iOS）渲染插件的落地路径：
  * [ ] 原生 Canvas 自绘方案 (结合 `wgpu` 插件)。
  * [ ] 操作系统原生基础组件映射方案。

### ⬜ 阶段五：Lite Codex 集成与自动验证
* [ ] 基于标准 TUI 目标和 HTTPS 插件，搭建 Lite Codex Agent 执行循环。
* [ ] 验证 `term.sai` epoll 事件驱动机制在长时间会话运行中的稳定性。
