# 开发环境说明

本项目的开发环境事实，集中记录于此（避免散落在各处）。

## 工具链

- **Flutter SDK**：3.44.8 stable，位于 `D:\flutter`（PATH 已含 `D:\flutter\bin`）
  - 注意：新开的终端/会话需要手动补 PATH：`$env:Path += ';D:\flutter\bin'`
- **Dart**：随 Flutter 自带（3.12.2），`dart` 命令同目录
- **VS Build Tools 2022**：17.14.37，路径 `C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools`
  - 已装组件：MSVC C++ 工具集、CMake、Windows 10 SDK（19041）
  - `flutter doctor` Windows 检查全绿，Windows 桌面版可正常构建
- **Android 工具链**：未安装（项目开发前期不需要，`flutter doctor` 会报 Android 红灯，属预期）

## 已知坑：VS workload 标记

微软 17.14 通道清单（vsman）缺失 `NativeDesktop`/`VCTools` workload 定义，导致 VS 安装器无法正常安装这两个 workload，`flutter doctor` 曾报"Visual Studio is missing necessary components"。

已解决方式：手动补写实例的 `state.packages.json`，加入两个 Workload 条目（`C:\ProgramData\Microsoft\VisualStudio\Packages\_Instances\<实例id>\state.packages.json`）。

**不要用 `setup.exe modify` 重装/改动组件**——它重写该文件会冲掉手动标记；若被冲掉，重跑补丁脚本 `C:\Users\botao\AppData\Local\Temp\opencode\fix_vs_state.ps1`（需管理员）。

## MCP

- **Dart/Flutter 官方 MCP**（`dart mcp-server`）：已配置在全局 `C:\Users\botao\.config\opencode\opencode.jsonc`（注意扩展名是 jsonc，不是 json）
  - 功能：启动应用、查看 widget 树、截图、热重载等，通过连接运行中的 Flutter 应用的 VM Service 工作
- 浏览器调试：chrome-devtools MCP（对 Flutter 桌面应用不适用，仅网页）
