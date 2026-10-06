# PLAN.md — 设计与协议说明

「探索的时光 Adventuring Time」：纯本地足迹地图 Flutter 应用，记录长期地点、行程、路径与人生轨迹线，数据全本地（GPX + JSON），无云服务。

本文件是**设计契约**：数据存储与模型、GPX 扩展格式、轨迹线与统计规则、同步与导入导出协议、Android 实时记录机制、实现偏差。日常操作约定、代码架构、构建发布见 AGENTS.md。

**代码为最终依据**：若本文件与代码冲突，以代码为准，并回头修订本文件。

## 1. 技术栈

- Flutter（Windows + Android 单代码库），Riverpod 状态管理
- 地图：`flutter_map` + `latlong2` + `flutter_map_cancellable_tile_provider`；瓦片源为 WGS-84 栅格源，默认源墙内可直连，设置页可切换（清单见 README「瓦片源」）
- 地址搜索/反向地理编码：Photon（可切 Nominatim）
- GPX：`xml`；定位：`geolocator` + 自写 Kotlin 前台服务
- 同步：`dart:io` HttpServer（服务端）+ `http`（客户端）；zip：`archive`；校验：`crypto`（sha256）
- 文件/图片/配置：`path_provider` / `file_selector` / `image_picker` / `shared_preferences` / `uuid` / `path` / `url_launcher`
- 坐标一律 WGS-84，不做 GCJ-02 转换

## 2. 存储与数据模型

### 2.1 根目录

- Windows 默认 `%USERPROFILE%\AdventuringTime\data`（设置中可改）；Android `getApplicationSupportDirectory()/data`
- 两端目录结构一致，同步即文件搬运；id 为本地生成的无连字符 UUID

### 2.2 目录结构

```
data/people/<personId>/
  profile.json
  life.gpx                        # 长期地点（waypoint）
  media/                          # 全人统一媒体池：<mediaId>.<ext>
  manifest.json                   # 同步状态：lifeUpdatedAt / lastSyncAt / tombstones
  trips/<tripId>/
    trip.json                     # 行程元数据
    trip.gpx                      # trk 路径 + wpt 地点
  backups/<yyyyMMdd-HHmmss>[-suffix]/   # profile/life/各行程，媒体不进备份
```

### 2.3 profile.json

```json
{ "id": "<personId>", "name": "姓名", "avatar": "<mediaId 或 null>", "bio": "简介（可选）", "createdAt": "ISO8601", "updatedAt": "ISO8601" }
```

### 2.4 trip.json

```json
{ "id": "<tripId>", "name": "新疆8日游", "description": "可选", "mediaIds": [], "startDate": "ISO8601", "endDate": "ISO8601 可选", "startEventId": "<长期地点id 或 null>", "endEventId": "同上", "createdAt": "ISO8601", "updatedAt": "ISO8601" }
```

### 2.5 媒体池

- 图片统一存 `media/<mediaId>.<ext>`，引用只存 mediaId（不含扩展名），读取按 basename 前缀扫描
- 引用字段统一为 `mediaIds` 列表（GPX/JSON 内写逗号分隔；旧单值 `mediaId`/`avatar` 读取兼容）
- 按需加载，不预生成缩略图；地图不直接附图
- 删除人/行程/备份后 `pruneOrphanMedia` 扫描当前数据与全部备份的引用，物理删除未被引用的媒体；备份本身不含媒体文件
- 导出/同步行程时按引用打包媒体

## 3. GPX 格式与 atrip 扩展

命名空间 `xmlns:atrip="urn:adventuring-time"`。解析时未知扩展跳过不报错，保证外部 GPX 可导入、本软件 GPX 外部可读。

### 3.1 扩展字段

| 字段 | 挂在 | 含义 |
|---|---|---|
| `atrip:id` | wpt / trk / rte | 本地 id |
| `atrip:eventType=life` | wpt | 该 waypoint 是长期地点 |
| `atrip:timePrecision` | wpt | `year\|month\|day`，时间模糊精度（year 时 time 为当年 1月1日） |
| `atrip:fromName` / `fromLat` / `fromLon` | wpt | 长期地点 A→B 起点（可选） |
| `atrip:mediaId` / `atrip:mediaIds` | wpt / trk / rte | 首张兼容 / 逗号分隔全部媒体 |
| `atrip:createdAt` / `atrip:updatedAt` | wpt / trk / rte | 时间戳 |
| `atrip:startEventId` / `startLat` / `startLon`、`endEventId` / `endLat` / `endLon` | trk / rte | 行程起终点引用 + 坐标快照 |
| `atrip:orderIds` | gpx 顶层 extensions | 行程内手动调序 id 列表（逗号分隔，空=按时间排序） |
| `atrip:trip`（metadata.extensions 内） | metadata | 行程元数据 id/name/description/mediaIds/startDate/endDate/startEventId/endEventId/createdAt/updatedAt |

### 3.2 元素形式

- 长期地点/行程地点：`<wpt>`（长期地点带 `eventType=life`）
- GPS 轨迹：`<trk>`，`<trkseg>` 内 `<trkpt>` 带 `<time>`
- 手绘路径：`<rte>`，子元素 `<rtept>` 无 time
- **单一存储**：长期地点只存 life.gpx（UI 不允许归入行程；解析兼容 trip.gpx 内 eventType=life），普通地点必归属某 trip.gpx
- 行程元数据写入 `<metadata>`；同步/导入优先读 trip.json，外部 GPX 回退 metadata

### 3.3 起终点引用

- 引用有效时行程首尾实时连到长期地点，标签显示其名称、可点击跳转
- 长期地点被删除 → 引用退化为快照坐标，轨迹不断裂；被移动 → 起终点实时跟随
- 外部 GPX 无扩展字段 → 无引用，正常显示

## 4. 核心概念与规则

### 4.1 长期地点

- `Waypoint.isEvent=true`；字段：id、name、desc、latLng、time（标志时间点，必填）、timePrecision（年/月/日）、fromName/fromLatLng（可选）、mediaIds、createdAt、updatedAt
- 时间显示按精度格式化；排序一律按 time，同刻按 createdAt
- 参与时间线与轨迹线

### 4.2 行程

- 包含：多条路径（trk/rte）+ 地点 wpt + trip.json 元数据
- 起终点引用同人长期地点（§3.3）
- 作为轨迹线上的一个"行程项"

### 4.3 人生轨迹线（派生视图，不落盘）

- 全部长期地点 + 全部行程按时间排序（长期地点用 time，行程用 startDate，同刻按 createdAt）
- 相邻项之间连**推算虚线**；任一端为行程的段带 tripId，供地图点击打开行程卡片
- 行程内部：起点长期地点 → 各路径首尾/地点 → 终点长期地点，全部虚线；顺序与行程详情一致（按日期分组、组间日期升序，组内 orderIds 覆盖全部项时按自定义顺序、否则按时间）；路径只连首尾，不重复绘制路径本身
- 轨迹线只画连线，不重复画路径；改 `buildLifePath`（lifecycle.dart）必跑 `test/lifecycle_test.dart`

### 4.4 统计口径

- 每人：记录里程、推算里程（分列）、长期地点数、行程数、照片数
- 记录里程 = 全部 GPS 轨迹长度之和；推算里程 = 各虚线连接段 haversine 之和
- 每行程：记录里程（GPS 轨迹）、推算里程（行程内连接段）、天数（GPS 点日期数；无则起止日期差+1；否则有路径为 1）、地点数、路径数、照片数
- haversine（WGS-84 地球半径 6371000m）
- GPS 速度：平均=总路程/首末时间差（含暂停）；最高瞬时=相邻有效段（间隔 ≤21s 且时间正序）中 dist/dt 最大者；超 21s 视为无信号段，不参与

### 4.5 GPS 轨迹切分

- 地图路径卡片对 GPS 轨迹（点数 ≥4）提供「切分轨迹」：进入切分模式，点击轨迹附近吸附最近采样点（两侧各需至少 2 点）；点「完成切分」弹确认框预览前后两段的名称、长度与速度
- 切分后两段同属原行程：前段保留原轨迹（id/说明/照片/起终点引用/创建时间不变，仅截取前半段点；名称若为默认时间名，则按切分后的新结束时间重生成）；后段为新轨迹（名称按新起始时间用录制同款格式生成、沿用原说明、无照片与起终点引用）
- 若 orderIds 含原轨迹，新轨迹插入其后；一次落盘（一次备份）

## 5. 局域网同步协议

### 5.1 形态

- Windows 内置 HTTP 服务器（默认端口 8024，设置可改），只做文件读写，合并决策全在客户端（两端同一套逻辑）
- 双向并集合并，以"人"为单位

### 5.2 同步单元

- 单元：`{type, unitId, updatedAt, sha256, size, deleted}`，key=`type:unitId`
- type：`profile`（unitId=profile）/ `trip`（unitId=tripId，打包 zip：trip.json+trip.gpx+引用媒体）/ `life`（整份 life.gpx）/ `media`（单文件，unitId=文件名）
- 墓碑（deleted）存 manifest.json 的 `tombstones`（trip/life/media），随清单传播

### 5.3 API（Windows 服务端）

```
GET  /api/ping                                  → {name, version, port}
GET  /api/people                                → [{id, name, updatedAt}]
POST /api/backup                                → 服务端全体备份
GET  /api/person/<pid>/manifest                 → {units: [...]}
GET  /api/person/<pid>/unit?type=&unitId=       → 单元内容
POST /api/person/<pid>/unit?type=&unitId=&updatedAt=&sha256=&deleted=  → 推送单元（服务端校验 sha256）
```

### 5.4 合并流程

```
mergePerson(personId, remote):
  1. 本地备份，构建两端 manifest
  2. 逐单元：
     仅对方有（非墓碑）→ 拉取；对方墓碑 → 跳过
     仅本地有 → 推送（本地墓碑则推空删除标记）
     双方都有：一方墓碑 → 删除/推墓碑
               sha 相同 → 跳过
               updatedAt 新者胜（被覆盖方旧版先入备份）
  3. 本地引用但媒体池缺失的媒体，按引用从远端补齐
  4. 记录 lastSyncAt
```

- 冲突兜底：同单元两边都改取 updatedAt 较新，不做字段级合并
- `syncAll`：先让远端备份，再对两端人物并集逐个 `mergePerson`

### 5.5 备份与恢复

- `backups/<yyyyMMdd-HHmmss>[-suffix]/`：只含 profile/life/各行程（`trip_<id>.json`/`gpx`），**媒体不进备份**
- 全量备份（同步前/覆盖导入前/写盘自动）：与最近一次备份文件集合与内容完全一致时跳过；手动备份 force 始终生成
- 支持按单元恢复、整时间戳恢复、删除备份；恢复后清理孤儿媒体

## 6. 导入导出

已实现——人物整包 `.atrip`：

- 内容：zip `{profile.json, life.gpx, trips/<id>/…, media/（仅被引用的）}`
- 导出：当前人物，或把某备份时间戳导出（媒体从媒体池补齐）
- 导入：personId 已存在时选"覆盖"（旧数据先备份）或"合并"（复用 `mergePerson`）；否则直接落盘

未实现：单行程导出/导入、单人全量 GPX（含人生轨迹 trk）、外部 GPX 导入（见 §8）。

## 7. Android 实时轨迹记录

自写 Kotlin 前台服务插件（method channel `adventuring_time/location`）：

- `LocationForegroundService`：`LocationManager` 定位（GPS 优先、网络兜底；GPS 有 fix 时 15s 内忽略网络点防抖）
- 权限（AndroidManifest）：`INTERNET`（release 必须显式声明）、`FOREGROUND_SERVICE`、`FOREGROUND_SERVICE_LOCATION`、`ACCESS_FINE/COARSE_LOCATION`、`POST_NOTIFICATIONS`、`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`
- 采样在原生侧：位移 >20m 或间隔 >20s 记一点，点即写 `filesDir/rec_session.jsonl`（每行一原始点）
- 会话状态 `rec_state` 只存 `startMs`；**无暂停，路径一定一整段，计时=当前-会话开始，大退/被杀也算时间**；服务被杀 `START_STICKY` 按 startMs 恢复并向同一文件追加，数据不丢；重进应用从文件恢复会话
- 服务仅"记录中"运行，空闲停止、通知消失；定位频率由 Dart 按前后台 `setMode` 切换（前台 1s / 后台 5s）；前台模式每次定位都推实时位置给蓝点（与采样解耦）
- UI 全在 `map_page.dart`（无独立记录页）：左上开始/停止（停止弹保存对话框）、右上信息条（时长/里程/实时速度）、橙色实时轨迹层、蓝点、右下回位（复位正北）；编辑模式隐藏浮层
- 蓝点：记录中 geolocator 持续订阅（含后台，GPS 热、回前台不冷启动）；未记录时进后台延迟 60s 取消、回前台重订阅并用系统最后位置兜底；取 geolocator 与服务实时位置两源中定位时间最新者；添加地点模式下点蓝点=当前位置添加地点
- 保存：`showRecordSaveDialog`（dialogs.dart）→ 选/新建行程，存为该行程一条 trk

## 8. 边界、风险与实现偏差

- **瓦片无数据区域降级（已论证，未实施）**：flutter_map 8 对"加载中/未加载"瓦片自动用低 zoom 祖先兜底，但对加载失败（404/无数据）不兜底（灰块）。方案：`TileLayer.errorTileCallback` 中逐级取祖先瓦片替换 `tile.imageInfo` + `notifyListeners`；Esri 无数据区返回 404 走该路径。待确认后实施
- **未实现的规划功能**：单行程导出/导入、单人全量 GPX、外部 GPX 导入、跨人起终点引用（选择器只列同人长期地点）
- 折线顶点编辑为自实现；人生轨迹线未做 Douglas-Peucker 抽稀（当前数据规模无需）
- Android 厂商省电策略可能杀后台：前台服务 + 电池白名单请求
