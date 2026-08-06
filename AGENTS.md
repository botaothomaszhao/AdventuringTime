# AGENTS.md — 项目开发指引

探索的时光（Adventuring Time）：纯本地足迹地图 Flutter 应用，记录一个人的长期地点、行程、路径与人生轨迹线。数据全本地（GPX + JSON），无云服务。

## 常用命令

```bash
flutter analyze lib            # 静态检查（仅看 error；driver_main 的两个 future 警告为已知）
flutter test                   # 19 个测试，须全绿后提交
flutter build windows --release
```

- Flutter SDK 在 `D:\flutter`；新终端需 `$env:Path += ';D:\flutter\bin'`
- Release 产物：`build\windows\x64\runner\Release\adventuring_time.exe`
- 墙内网络：瓦片用 Esri（默认，WGS-84）；搜索/反地理编码用 Photon。OSM/Nominatim 不可用，勿切换验证

## 架构（lib/）

| 文件 | 职责 |
|---|---|
| `models.dart` | Person/Trip/Waypoint/PathData/TrackPoint/GpxFile/TripBundle；`isEvent=true`=长期地点 |
| `gpx_io.dart` | GPX 解析/序列化（atrip 扩展字段：isEvent、timePrecision、起终点引用） |
| `storage.dart` | 磁盘读写：people/life/trips/media/backups；写前自动备份 |
| `providers.dart` | Riverpod：personDataProvider（单人全量数据 PersonData）、写操作统一在此（先落盘再更新 state） |
| `lifecycle.dart` | 纯函数：haversine、buildLifePath（轨迹线）、tripStats、formatLatLng |
| `geo_search.dart` | Photon 搜索 searchAddress / 反向 reverseAddress |
| `tile_cache.dart` | 瓦片磁盘缓存 |
| `views/map_page.dart` | 地图主页面（核心，改动最多） |
| `views/dialogs.dart` | 全部表单对话框（地点/路径/行程/人）；`pickValueDialog` 年/月选择器 |
| `views/timeline_page.dart` | 时间线（长期地点+行程混合，`buildTimelineItems` 纯函数可测） |
| `views/trip_detail_page.dart` | 行程详情（说明内联编辑 `_EditableDesc`） |
| `views/person_shell.dart` | 主壳（Tab 地图/时间线/统计）+ `mapPageActionProvider`（跨页定位地图） |
| `views/stats_page.dart` / `settings_page.dart` / `widgets.dart` | 统计 / 设置（瓦片源、数据目录）/ 公共组件 |
| `driver_main.dart` | MCP 测试入口（见下） |

## 数据模型要点

- **长期地点**：`Waypoint.isEvent=true`，存 life.gpx，必填到达时间（time+timePrecision 年/月/日），参与时间线/轨迹线，可移入行程
- **普通地点**：必须归属某行程（对话框下拉必选），存 trip.gpx
- **路径**：GPS（trk，点带 time）或手绘（rte，点无 time）；手绘路径的时间通过对话框设置（写入 points[0].time，供轨迹线排序）
- **行程起终点**：Trip.startEventId/endEventId 引用长期地点
- 数据根目录：`%USERPROFILE%\AdventuringTime\data\people\<personId>\`

## 关键业务流程

- **地图点击命中** `map_page.dart _openAt`：点击位置与所有路径/连接线做屏幕像素距离检测（阈值 10px），**路径优先**（打开路径卡片），其次行程连接线（打开行程卡片）。不依赖 hover，勿改回 hitNotifier 方案
- **轨迹线** `buildLifePath`：长期地点+行程按时间排序；行程内部路径/地点/起点长期地点按时间相连、**最后连回终点**；段带 `tripId` 供点击打开行程。改它必跑 `test/lifecycle_test.dart`
- **绘制路径**：点"绘制路径"→ 点击落点（onTapDown 加点，onTapCancel 撤销误加点）→ 工具栏"完成"→ 选行程 → 路径对话框。预览线必须在 FlutterMap children 内且 `_draftPoints.isNotEmpty` 才渲染（放外面会抛 MapCamera.of 错误页，空点会断言崩溃——两个都踩过坑）
- **添加地点**：地图落点 → 对话框（名称可异步反向地理编码、到达时间必填、长期地点或选所属行程）。从行程卡片"添加地点"进入时预选行程并预填时间（行程开始或最后地点/路径时间）

## 测试与验证

- 单元/组件测试：`test/`（gpx_io/lifecycle/storage/widget）；**提交前 flutter test 全绿**
- **MCP 驱动测试**：`flutter run -d windows -t lib/driver_main.dart` 提供自定义 handler（addWaypoint/addPath/getData/focusMap/reverse/uiState 等），配合 `dart_dtd connect` + `dart_flutter_driver_command`。**Windows 上 driver tap 地图/按钮不可靠**，多用于对话框流程与数据验证
- **Windows 窗口验证**：driver 无法 hover/拖拽；确认渲染/点击效果用 Win32 模拟真实鼠标点击（SetCursorPos+mouse_event，注意后台窗口首次点击只激活），或截屏后用 describe-image 查看
- 测试数据人物 id 会变（用户会在应用里增删人物）；用 `getData` 先查当前 id 再操作，勿硬编码

## 约定与陷阱

- 回复与注释用中文，无 emoji（全局 AGENTS.md 已约定）
- 不写无意义代码；对外部输入做必要校验；基础依赖不可用直接抛错
- `analysis_options.yaml` 用 flutter_lints 6；勿引入新的状态管理/地图方案
- 修改 models/gpx_io 时同步检查 `test/gpx_io_test.dart` 与 `storage_test.dart`
- 地图图层开关（_LayerToggles）是内存态，默认全开
