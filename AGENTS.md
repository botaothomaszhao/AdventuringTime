# AGENTS.md — 项目开发指引

探索的时光（Adventuring Time）：纯本地足迹地图 Flutter 应用，记录一个人的长期地点、行程、路径与人生轨迹线。数据全本地（GPX + JSON），无云服务。

## 开发环境

- **Flutter SDK**：3.44.8 stable，位于 `D:\flutter`；Dart 3.12.2 随自带，`dart` 命令同目录
- **Android 工具链**：SDK 位于 `D:\Android\sdk`（36.0.0），`flutter doctor` Android 绿灯；Java 23 已装；adb 在 `D:\Android\sdk\platform-tools\adb.exe`
- **真机**：开发者选项"USB 安装"不可用 → 用 adb push + 手机文件管理器手动安装 APK
- **VS Build Tools 2022**：17.14.37，路径 `C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools`；已装组件：MSVC C++ 工具集、CMake、Windows 10 SDK（19041），`flutter doctor` Windows 检查全绿

### 已知坑：VS workload 标记

微软 17.14 通道清单（vsman）缺失 `NativeDesktop`/`VCTools` workload 定义，导致 VS 安装器无法安装这两个 workload，`flutter doctor` 曾报 "Visual Studio is missing necessary components"。

已解决方式：手动补写实例的 `state.packages.json`，加入两个 Workload 条目（`C:\ProgramData\Microsoft\VisualStudio\Packages\_Instances\<实例id>\state.packages.json`）。

**不要用 `setup.exe modify` 重装/改动组件**——它重写该文件会冲掉手动标记；若被冲掉，重跑补丁脚本 `%USERPROFILE%\AppData\Local\Temp\opencode\fix_vs_state.ps1`（需管理员）。

### 已知坑：gradle Kotlin 增量缓存冲突

插件模块 Kotlin 编译任务并发写同一增量缓存报 `Could not close incremental caches ... Storage is already registered`，已通过 `android/gradle.properties` 中 `org.gradle.parallel=false` + `kotlin.incremental=false` 解决；若仍报错，先杀残留 java 进程（gradle/kotlin daemon）再构建。

### MCP

- **Dart/Flutter 官方 MCP**（`dart mcp-server`）：已配置在全局 `%USERPROFILE%\.config\opencode\opencode.jsonc`（注意扩展名是 jsonc，不是 json）；功能：启动应用、查看 widget 树、截图、热重载等，通过连接运行中的 Flutter 应用的 VM Service 工作
- 浏览器调试：chrome-devtools MCP（对 Flutter 桌面应用不适用，仅网页）

## 常用命令

```bash
flutter analyze lib            # 静态检查（仅看 error；driver_main 的两个 future 警告为已知）
flutter test                   # 39 个测试，须全绿后提交
flutter build windows --release
flutter build apk --release    # 安卓 release（debug key 签名）；成功后 push 到手机（文件名带版本号，如 adventuring_time_1.1.3.apk）：
# & D:\Android\sdk\platform-tools\adb.exe push build\app\outputs\flutter-apk\app-release.apk /sdcard/Download/adventuring_time_<versionName>.apk
# 手机文件管理器手动安装；签名变化（如 debug→release）需先卸载旧版
```

- Flutter SDK 在 `D:\flutter`；新终端需 `$env:Path += ';D:\flutter\bin'`
- Release 产物：`build\windows\x64\runner\Release\adventuring_time.exe`（构建前若 exe 被占用需先杀 `adventuring_time` 进程）
- 墙内网络：瓦片用 Esri（默认，WGS-84；国内部分区域高等级无数据，可换 Carto Voyager——实测墙内可用）；搜索/反地理编码用 Photon。OSM/Nominatim 不可用，勿切换验证
- **版本号规则**：`pubspec.yaml` 的 `version: 1.0.x+buildNumber`，每次发 APK 时 versionName 最后一位自增、buildNumber 同步递增（Android 覆盖安装强校验 versionCode 单调增大，buildNumber 不能回退）；同时同步更新 `lib/version.dart` 的 `appVersion`（设置页"关于"显示，现仅 versionName 不带 buildNumber），否则关于里的版本号会落后

## 启动应用（避免卡死/重复进程占用）

**不要用 `Start-Process flutter.bat` 或直接 `flutter run` 起后台**：opencode 终端会等待整个进程树结束（flutter 工具派生 dart/app 子进程后仍不返回），表现为命令看似没执行完。**改用 WScript.Shell.Run 让 Flutter 进程脱离进程树监控（成为"孤儿"），脚本返回后外部工具不再阻塞**：

```powershell
# 先杀残留进程（旧实例占用 exe 会导致构建/运行失败；重复实例也会互相干扰）
Get-Process -Name "adventuring_time" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
$ws = New-Object -ComObject WScript.Shell
$cmd = 'cmd /c "D:\flutter\bin\flutter.bat run -d windows > %USERPROFILE%\AppData\Local\Temp\opencode\flutter_run.log 2> %USERPROFILE%\AppData\Local\Temp\opencode\flutter_run_err.log"'
$ws.Run($cmd, 0, $false)   # 0=隐藏窗口, false=不等待
# 轮询进程出现（约 30-90s），再 sleep 十几秒等数据/瓦片就绪；从日志 grep "VM Service" 拿调试地址
```

- `Start-Process` 直接跑 flutter.bat 会阻塞：flutter 进程树（flutter→dart→app）挂在 Start-Process 派生的子进程下，外部终端一直等待整棵树结束
- 退出后统一 `Get-Process adventuring_time | Stop-Process -Force` 清理，避免下次启动时旧实例占用

## 架构（lib/）

| 文件 | 职责 |
|---|---|
| `models.dart` | Person/Trip/Waypoint/PathData/TrackPoint/GpxFile/TripBundle；`isEvent=true`=长期地点 |
| `gpx_io.dart` | GPX 解析/序列化（atrip 扩展字段：isEvent、timePrecision、起终点引用、orderIds） |
| `storage.dart` | 磁盘读写：people/life/trips/media/backups；写前自动备份（内容无变化时跳过，手动备份 force 始终生成） |
| `providers.dart` | Riverpod：personDataProvider（单人全量数据 PersonData）、写操作统一在此（先落盘再更新 state）；含 `reorderTripItem` 行程内按天调序 |
| `lifecycle.dart` | 纯函数：haversine、buildLifePath（轨迹线）、tripStats、formatLatLng |
| `geo_search.dart` | Photon 搜索 searchAddress / 反向 reverseAddress |
| `tile_cache.dart` | 瓦片磁盘缓存 |
| `location_service.dart` | 安卓定位通道封装 + `recordingProvider`（RecordingNotifier 记录会话，恢复/暂停/停止）；Windows 不 watch |
| `views/map_page.dart` | 地图主页面（核心，改动最多）；安卓含蓝点、记录浮层（左上按钮/右上信息条/右下回位）、实时轨迹层 |
| `views/dialogs.dart` | 全部表单对话框（地点/路径/行程/人）；`pickValueDialog` 年/月选择器；`showRecordSaveDialog` 轨迹保存 |
| `views/timeline_page.dart` | 时间线（长期地点+行程混合，`buildTimelineItems` 纯函数可测） |
| `views/trip_detail_page.dart` | 行程详情（说明内联编辑 `_EditableDesc`、按日期分组、组内手动调序 orderIds） |
| `views/person_shell.dart` | 主壳（Tab 地图/时间线/统计）+ `mapPageActionProvider`（跨页定位地图） |
| `views/stats_page.dart` / `settings_page.dart` / `widgets.dart` | 统计 / 设置（瓦片源即时生效、清除瓦片缓存、数据目录）/ 公共组件（`pickImageBytes` 分平台） |
| `driver_main.dart` | MCP 测试入口（见下） |

## 数据模型要点

- **长期地点**：`Waypoint.isEvent=true`，存 life.gpx，必填到达时间（time+timePrecision 年/月/日），参与时间线/轨迹线，可移入行程
- **普通地点**：必须归属某行程（对话框下拉必选），存 trip.gpx
- **路径**：GPS（trk，点带 time）或手绘（rte，点无 time）；手绘路径的时间通过对话框设置（写入 points[0].time，供轨迹线排序）
- **行程内手动调序**：`GpxFile.orderIds`（路径/地点 id 混合，仅行程内）；空 = 按时间排序，覆盖全部项时按自定义顺序展示
- **行程起终点**：Trip.startEventId/endEventId 引用长期地点
- 数据根目录：`%USERPROFILE%\AdventuringTime\data\people\<personId>\`

## 关键业务流程

- **地图点击命中** `map_page.dart _openAt`：点击位置与所有路径/连接线做屏幕像素距离检测（阈值 10px），**路径优先**（打开路径卡片），其次行程连接线（打开行程卡片）。不依赖 hover，勿改回 hitNotifier 方案
- **轨迹线** `buildLifePath`：长期地点+行程按时间排序；行程内部路径/地点/起点长期地点按时间相连、**最后连回终点**；段带 `tripId` 供点击打开行程。改它必跑 `test/lifecycle_test.dart`
- **绘制路径**：点"绘制路径"→ 点击落点（onTapDown 加点，onTapCancel 撤销误加点）→ 工具栏"完成"→ 选行程 → 路径对话框。预览线必须在 FlutterMap children 内且 `_draftPoints.isNotEmpty` 才渲染（放外面会抛 MapCamera.of 错误页，空点会断言崩溃——两个都踩过坑）
- **添加地点**：地图落点 → 对话框（名称可异步反向地理编码、到达时间必填、长期地点或选所属行程）。从行程卡片"添加地点"进入时预选行程并预填时间（行程开始或最后地点/路径时间）
- **安卓定位记录**（Kotlin 前台服务 + 地图页浮层，详见 PLAN.md §6.6）：左上按钮开始/停止、右上信息条（时长/里程/实时当前速度/暂停继续）、橙色实时轨迹层、蓝点（空闲用 geolocator 流，记录会话期间改用前台服务实时位置，记录/暂停均实时不跳变；添加地点模式下点蓝点=在当前位置添加地点）、右下角回位按钮（方向复位正北）。采样（20m/30s，后台降频 5s）与落盘都在原生侧（`filesDir/rec_session.jsonl` + `rec_state`），**每采一点即结算段时长**，被杀自动恢复续记（无点时段不计入时长）；重进 app 时 RecordingNotifier 从原生拉回会话。GPS 轨迹保存后展示平均/最高速度（口径见 `pathSpeedStats`，超 31s 间隔段不计瞬时）。Windows 上所有相关 UI 走 `Platform.isAndroid` 分支且不 watch `recordingProvider`

## 测试与验证

- 单元/组件测试：`test/`（gpx_io/lifecycle/storage/widget）；**提交前 flutter test 全绿**
- **MCP 驱动测试**：`flutter run -d windows -t lib/driver_main.dart` 提供自定义 handler（addWaypoint/addPath/getData/focusMap/reverse/uiState 等），配合 `dart_dtd connect` + `dart_flutter_driver_command`。**Windows 上 driver tap 地图/按钮不可靠**，多用于对话框流程与数据验证
- **Windows 窗口验证**：driver 无法 hover/拖拽；确认渲染/点击效果用 Win32 模拟真实鼠标点击（SetCursorPos+mouse_event，注意后台窗口首次点击只激活），或截屏后用 describe-image 查看
- 测试数据人物 id 会变（用户会在应用里增删人物）；用 `getData` 先查当前 id 再操作，勿硬编码

## 约定与陷阱

- 回复与注释用中文，无 emoji（全局 AGENTS.md 已约定）
- **文档需及时更新**：功能/数据模型/命令/测试数等有实质变化时，同步更新 README.md、PLAN.md、AGENTS.md 与涉及的功能说明，随提交一起进版本，不留欠账
- 不写无意义代码；对外部输入做必要校验；基础依赖不可用直接抛错
- `analysis_options.yaml` 用 flutter_lints 6；勿引入新的状态管理/地图方案
- 修改 models/gpx_io 时同步检查 `test/gpx_io_test.dart` 与 `storage_test.dart`
- 地图图层开关（_LayerToggles）是内存态，默认全开
- **GitHub 推送**：本机直连 github.com 不通。git push 失败就停下来，请用户开梯子后重试——不要自己配置代理或连代理
- **release APK 必须显式声明 INTERNET 权限**（main AndroidManifest.xml）：Flutter 只在 debug/profile 构建自动注入，release 缺了会瓦片/搜索全部失败（踩过坑）
- 瓦片源在设置页保存后即时生效（invalidate tileUrlProvider）；设置页有"清除瓦片缓存"按钮（删应用数据/tiles 目录）
- 瓦片无数据区域（Esri 国内部分高等级）当前直接显示灰块；低 zoom 放大兜底方案已论证未实施（见 PLAN.md §13）
