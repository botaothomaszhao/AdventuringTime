# 「探索的时光」(Adventuring Time) 实现计划

本文件是项目的完整实现依据。任何具备 Flutter 开发能力的 agent 应能仅依据本文件写出完整、可运行的 Windows + Android 双端应用。实现细节以本文件为准，若与既有代码冲突，先暂停询问。

---

## 1. 项目概述

一款纯本地、无服务器的足迹地图软件：

- 在地图上保存历史行程轨迹（实时记录 + 手动添加），地点与路径均可编辑、附图、附文字说明
- 支持"生活事件"（出生城市、搬家年份等）作为个人时间线，时间可模糊（只显示年份）
- 支持"行程合集"（如"新疆8日游"）：多段路径 + 相关地点组成一个大行程
- 支持多人：每人的数据是一个独立目录组
- Windows + Android 双端，局域网内可同步（Windows 做服务器）
- 全部数据本地存储；格式以 GPX 为主、自有扩展为辅；支持导入导出
- 简单统计（里程、天数、地点数、照片数）

## 2. 技术栈与依赖

- Flutter（Windows desktop + Android，单代码库）
- `flutter_map` + `latlong2` + `flutter_map_cancellable_tile_provider`：地图（在线瓦片 + 本地缓存）
- `geolocator`：定位
- 自写 Kotlin 前台服务插件（method channel）：Android 持续轨迹记录
- `xml`：GPX 解析/生成
- Riverpod：状态管理
- `path_provider`、`file_picker`、`file_selector`、`image_picker`：文件/图片选择
- `dart:io HttpServer`：Windows 端内置同步服务器（无第三方服务）
- `http`：Android 端同步客户端
- 坐标一律 WGS-84（与 GPX、OSM 一致，不做 GCJ-02 转换）

依赖选择原则：能用官方/主流包解决的问题不重复造轮子；定位前台服务因为商业库（flutter_background_geolocation）有授权问题，必须自写。

## 3. 数据存储与数据模型

### 3.1 存储根目录

- Windows：`%USERPROFILE%\AdventuringTime\data`（设置中可改）
- Android：应用私有目录（`getApplicationSupportDirectory()/data`）
- 两端目录结构完全一致，同步即文件搬运

### 3.2 目录结构（每人为一个目录组）

```
data/
  people/<personId>/
    profile.json               # 个人信息
    life.gpx                   # 未归入行程的生活事件（waypoint + atrip 扩展）
    media/                     # 全人统一媒体池：<mediaId>.<ext>
    trips/<tripId>/
      trip.json                # 行程元数据（含起终点事件引用）
      trip.gpx                 # tracks（路径/轨迹）+ waypoints（地点、已归入行程的事件）
    backups/                   # 同步/删除/覆盖时自动备份：<时间戳>/<单元>（见 §7.5）
  manifest.json                # 可选：数据版本号/各人最近同步时间
```

`personId` / `tripId` / `eventId` / `mediaId` 均为本地生成的 UUID（hex 或短 id，无连字符）。

### 3.3 profile.json

```json
{
  "id": "<personId>",
  "name": "姓名",
  "avatar": "<mediaId 或 null>",
  "bio": "简介（可选）",
  "createdAt": "ISO8601",
  "updatedAt": "ISO8601"
}
```

### 3.4 trip.json

```json
{
  "id": "<tripId>",
  "name": "新疆8日游",
  "description": "可选",
  "cover": "<mediaId 或 null>",
  "startDate": "ISO8601 日期（标志时间点）",
  "endDate": "ISO8601 日期（可选）",
  "startEventId": "<eventId 或 null>",   // 起终点引用（可选，仅限同人）
  "endEventId": "<eventId 或 null>",
  "createdAt": "ISO8601",
  "updatedAt": "ISO8601"
}
```

### 3.5 媒体池规则

- 所有图片统一存 `people/<personId>/media/<mediaId>.jpg`
- 事件、行程地点、路径、行程封面只存 `atrip:mediaId` 引用
- 图片按需加载（点开事件/行程详情时才显示），不做缩略图预生成；地图上不直接附图
- **不做引用计数/去重/删除检查**：图片单次上传，删除即物理删除，允许留下悬空引用（渲染时忽略）
- 行程单独导出 zip 时，按引用把所需媒体复制进包的 `media/`，源池不动

## 4. GPX 格式与扩展

### 4.1 命名空间

自定义扩展统一用命名空间：`xmlns:atrip="urn:adventuring-time"`。解析/生成时对未知扩展字段跳过不报错，保证外部 GPX 可导入、本软件 GPX 外部可读。

### 4.2 atrip 扩展字段清单

| 字段 | 类型 | 挂在 | 含义 |
|---|---|---|---|
| `atrip:timePrecision` | `year\|month\|day` | wpt | 时间模糊精度；`year` 时 time 为当年 1月1日0:0 |
| `atrip:eventType` | `life`（无则普通地点） | wpt | 标记该 waypoint 是生活事件 |
| `atrip:fromName` | string | wpt | 事件起点名（如旧居城市名） |
| `atrip:fromLat` / `atrip:fromLon` | double | wpt | 事件起点坐标（可选，存在时画 A→B 虚线） |
| `atrip:mediaId` | string | wpt / trk / trkpt | 附图引用 |
| `atrip:startEventId` / `atrip:endEventId` | string | trk | 行程起终点引用 + 坐标快照（见 4.5） |
| `atrip:startLat` / `atrip:startLon` / `atrip:endLat` / `atrip:endLon` | double | trk | 起终点坐标快照 |
| `atrip:orderIds` | string | extensions（gpx 顶层） | 行程内路径/地点手动调序的 id 列表（逗号分隔）；空 = 按时间排序 |

### 4.3 生活事件 → GPX（life.gpx 中为 wpt）

```xml
<wpt lat=".." lon="..">
  <name>搬家到上海</name>
  <desc>2008年全家搬到上海</desc>
  <time>2008-01-01T00:00:00Z</time>
  <extensions>
    <atrip:eventType>life</atrip:eventType>
    <atrip:timePrecision>year</atrip:timePrecision>
    <atrip:fromName>武汉</atrip:fromName>
    <atrip:fromLat>..</atrip:fromLat>
    <atrip:fromLon>..</atrip:fromLon>
    <atrip:mediaId>..</atrip:mediaId>
  </extensions>
</wpt>
```

### 4.4 行程 → GPX（trip.gpx）

- GPS 轨迹用 `<trk>`，每条一个 trk，`<trkpt>` 带 `<time>`（有记录时间者）；扩展字段：`atrip:mediaId`、名称/描述用 `<name>/<desc>`
- 手绘路径用 `<rte>`，子元素为 `<rtept>`（非 trkpt），无 time 字段
- 行程地点为 `<wpt>`；**归入行程的事件**也是 `<wpt>` 且带 `atrip:eventType=life` + `timePrecision`
- 行程元数据（trip.json 内容）写入 `<metadata>` 的自定义子元素（同步、导入导出时优先读 trip.json，兼容外部 GPX 时回退 metadata）
- 行程内手动调序：gpx 顶层 `<extensions>` 写 `atrip:orderIds`（路径/地点 id 逗号分隔，空 = 按时间排序）

### 4.5 起终点引用 → GPX

`<trk><extensions>` 中存 `atrip:startEventId` + `atrip:startLat/startLon`（快照），结束端同理。规则：

- 引用有效（事件存在）时，地图上行程轨迹首尾与该事件坐标实时连接，起终点标签显示事件名（如"家"），可点击跳转
- 事件被删除 → 引用退化为普通起点/终点（用快照坐标，轨迹不断裂）
- 事件被移动 → 起终点实时跟随事件坐标
- 导入无扩展字段的外部 GPX → 无引用，正常显示

### 4.6 人生轨迹 → GPX（仅全量导出时）

一条 `<trk>`：按时间顺序的完整连线，实际记录段与推算直线段都写为 trkpt（直线段即两点），`<extensions>` 标注 `atrip:segment=dashed` 用于区分虚线段。

## 5. 核心概念与规则

### 5.1 生活事件 Event

- 字段：id、name、desc、lat/lon、time（标志时间点，ISO8601）、timePrecision（year/month/day）、fromName/fromLat/fromLon（可选）、mediaId（可选）、归属容器（life.gpx 或某 trip.gpx）、createdAt、updatedAt
- 时间显示按精度格式化："2008年" / "2008年3月" / 精确日期；排序一律按 `time`（同刻按 createdAt）
- **单一存储位置**：事件只存在 life.gpx，绝不重复存储

### 5.2 行程合集 Trip

- 包含：多条路径（trk/rte）+ 地点 wpt + trip.json 元数据
- 起终点可引用同人事件（见 4.5）
- 行程也可作为人生轨迹线上的一个"行程项"

### 5.3 人生轨迹线 Life Path（派生视图，不落盘）

由该人**全部事件 + 全部行程**按时间动态生成，每次展示时计算：

1. 排序：行程项用 trip.startDate，事件用 time，同刻按 createdAt
2. 顺序连接（相邻两项）：
   - 行程项贡献其内部轨迹（多条 track 按其内部时间排序连接；track 之间有间隔的，间隔处为推算直线段）
   - 事件→事件：直线
   - 事件→行程 / 行程→事件：事件点 ↔ 行程首/尾点之间直线
   - 环状序列（事件A-行程C-事件B-事件A）天然成立，即一条首尾相接折线
3. 显示：**实线 = 实际记录段，虚线 = 推算直线段**；整条线为一个可开关图层，每人独立
4. 统计：沿折线逐段 haversine 求和，实线段合计 = 记录里程，虚线段合计 = 推算里程

### 5.4 统计口径

- 每人：总记录里程 + 总推算里程（分开展示）、事件数、行程数、照片数
- 每行程：记录里程、推算里程（行程内部直线连接段：起点长期地点→各路径首尾/地点→终点长期地点，与轨迹线行程部分一致，不含 GPS 轨迹自身）、天数、地点数、路径数、照片数
- haversine（WGS-84 地球半径 6371000m）

## 6. 功能模块

### 6.1 地图

- flutter_map + OSM 标准瓦片；瓦片源 URL 可在设置中配置（默认 OSM，预留替换）；瓦片按需缓存至本地，无网络时使用缓存
- 图层：人列表 → 每人可开关：地点、路径、事件、人生轨迹线
- 同一时刻同屏可显示多人的数据
- 点击地点/事件/路径 → 底部弹卡：名称、时间、说明、统计、编辑/删除入口（图片不在此处显示，点进详情再加载）

### 6.2 编辑

- **地点（wpt）**：新增（点地图落点 / 搜索落点）、拖动改坐标、改名/说明/附图、删除；行程内地点与事件都可拖
- **路径**：两种类型——手绘路径（polyline，点地图连续落点，双击结束）与 GPS 轨迹（trk，来自实时记录或导入）
  - 编辑：选中路径进入编辑模式 → 显示顶点圆圈，可拖动顶点、在线上点击插入新顶点、删除顶点；可改名/说明/附图、整体平移（拖动整条）
- **事件**：新增（点地图/搜索落点）、编辑（时间 + 时间精度、A→B 可选起点、文字、附图）、删除
- **行程**：增删改基本信息、起终点引用事件（选择器只列同人事件）、封面图
- 所有写操作维护 updatedAt

### 6.3 地址搜索

- OSM Nominatim 地理编码（搜索框输入"xx镇" → 结果列表 → 落点）
- 请求带自定义 User-Agent（如 `AdventuringTime/1.0`）；失败提示重试
- 服务地址常量 + 预留替换（接口收敛为 `searchAddress(q) -> List<GeoResult>`）

### 6.4 时间线视图

- 按人展示：全部事件（life.gpx + 各行程中 eventType=life 的 wpt）按标志时间排序
- 模糊时间格式化显示；点击跳地图定位
- 时间线条目上可执行：编辑、删除

### 6.5 行程详情

- 基本信息、封面、起终点（含事件引用）、统计摘要（记录里程、推算里程、天数、地点数、路径数、照片数）
- 按日期分组列出路径与地点，点击跳地图；组内默认按时间排序，可上移/下移手动调序（orderIds 持久化，未覆盖全部项时按时间生成基准顺序再交换同天相邻项）
- 照片墙（行程引用的所有媒体）

### 6.6 安卓实时轨迹记录（已实现，与下述有出入时以本标注为准）

- 自写 Kotlin 前台服务插件（method channel，channel 名 `adventuring_time/location`）：
  - 服务类 `LocationForegroundService`：系统 `LocationManager` 定位（GPS 优先、网络兜底，GPS 有 fix 时 15s 内忽略网络定位点防抖动）；**前台 1s 定位、后台降频 5s**（采样阈值 20m/20s，低频无损）
  - AndroidManifest 权限：`INTERNET`（release 必须显式声明，debug 由 Flutter 自动注入）、`FOREGROUND_SERVICE`、`FOREGROUND_SERVICE_LOCATION`、`ACCESS_FINE_LOCATION`、`ACCESS_COARSE_LOCATION`、`POST_NOTIFICATIONS`、`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`
  - 采样在原生侧（不在 geolocator 流回调）：**位移 > 20m 或间隔 > 20s** 记一点，点即写落盘 `filesDir/rec_session.jsonl`（JSONL，每行一原始采样点）
  - 会话状态文件 `rec_state`（格式 `startMs`，只存会话开始时间；兼容旧版 `state|startMs|...`，旧暂停会话不恢复）：**无暂停，路径记录一定是一整段，计时=当前-会话开始，大退/被杀也算时间**；服务被杀后 `START_STICKY` 重启时按 startMs 恢复采样，继续向同一文件追加，**记录不中断、数据不丢**；重进应用从文件拉回全量点与开始时间恢复会话（服务未重启时先恢复采样）
  - 首次启动请求精确位置权限与电池优化白名单（`ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`，失败不阻塞）；Android 13+ 请求通知权限
  - **服务仅"记录中"运行**：空闲时服务停止、通知消失；定位频率由 Dart 按 app 前后台通过 `setMode` 动作切换（前台 1s / 后台 5s，后台不推位置给蓝点）；**前台模式每次定位都推实时位置到位置通道（与采样解耦，蓝点/实时速度每秒更新）**
- UI 在地图页内（**没有独立记录页**）：
  - 左上角按钮：空闲=开始记录（红点图标），记录中=停止并弹出保存
  - 右上角信息条：状态点、记录时长（=当前-会话开始，大退不归零）、已记录里程、实时速度（前台每秒位置差计算，非采样点）
  - 记录轨迹以橙色线实时绘制在地图上；蓝点实时位置：**记录中 geolocator 保持订阅（含后台，GPS 热、回前台不冷启动），未记录时进后台延迟 60s 再取消订阅（快速切回仍可用）、回前台重订阅并先以系统最后位置兜底；蓝点取 geolocator 与服务实时位置两源中定位时间最新者**；**添加地点模式下点击蓝点=在当前位置添加地点**；右下角按钮=回到我的位置并把地图方向复位正北（双指旋转已启用）
  - 编辑模式下隐藏记录浮层防遮挡
- 停止后保存对话框：选择/新建行程、轨迹名、说明、附图，存为该行程一条 trk（`showRecordSaveDialog`，在 dialogs.dart）

### 6.7 局域网同步

见 §7 完整协议。

### 6.8 导入导出

见 §8。

### 6.9 多人管理

- 人列表页：增删、编辑资料、整组导入导出（.atrip）
- 每人的数据独立操作互不影响；地图/时间线按人切换或叠加
- 删除人员：弹窗确认后，连带 backups 一起物理删除整个 person 目录

## 7. 局域网同步协议

### 7.1 形态

- Windows 端内置 HTTP 服务器（dart:io），默认端口 **8024**，设置中可改端口与查看本机 IP
- Android 端输入 `IP:端口`，手动触发"同步"（也可加"检测到服务器在线自动同步"开关）
- 双向并集合并，以"人"为单位进行

### 7.2 同步单元

同步以整文件为单元，不做条目级拆分：

- 行程：trip.json + trip.gpx + 该行程引用的媒体文件（打包为一个传输单元）
- 生活事件：整份 life.gpx 文件（全量传输，不做单条事件拆分）
- 媒体：单个文件（只增不改，无冲突）
- 每单元：`{type: trip|life|media, id(unitId), updatedAt, sha256, size, deleted}`

### 7.3 API（Windows 服务器）

```
GET  /api/people                        → [{id, name, updatedAt}]
GET  /api/ping                          → {name: "AdventuringTime", version, port}
GET  /api/person/<pid>/manifest         → {units: [同步单元清单]}
GET  /api/person/<pid>/unit?type=&unitId=  → 单元内容（行程=zip，life=原始 GPX，媒体=原始字节）
POST /api/person/<pid>/unit?type=&unitId=  → 推送单元（body 同上，服务端校验 sha256）
```

服务器只做文件读写，不做合并决策（合并逻辑在客户端，避免两端重复实现逻辑漂移）。

### 7.4 客户端合并流程（两端相同逻辑）

```
sync(personId, remote):
  1. 拉 remote.manifest，构建本地 manifest
  2. 对每单元：
     a. 仅对方有 → 拉取（并集新增）
     b. 仅本地有 → 推送
     c. 双方都有：
        - 一方 deleted → 本地方同步删除（删除前备份）
        - 双方均未 deleted → updatedAt 新者胜；被覆盖方的旧版本先写入本地 backups（不丢数据）
  3. 媒体按引用清单补齐（缺啥拉啥）
  4. 更新本地 lastSyncAt
```

- 冲突兜底：同单元两边都改 → 取 updatedAt 较新，旧版进备份，不做字段级精细合并
- 删除传播墓碑：manifest 中带 `deleted` 标记的单元会让对方同步删除，删除前备份

### 7.5 备份

- 目录：`people/<personId>/backups/<yyyyMMdd-HHmmss>/`
- 覆盖与删除动作发生时，把旧版本整体写入备份（行程=原 zip，life.gpx=原文件，媒体=原文件），不做条目级拆分
- 全量备份（同步前/覆盖导入前/写盘自动）：与最近一次备份的文件集合与字节完全一致时跳过，不产生重复备份；**备份对话框的手动备份始终生成**（force）
- UI 提供"从备份恢复"入口（列出备份时间戳 → 选择恢复单元）

## 8. 导入导出

### 8.1 行程导出/导入

- 导出单行程：`.atrip-trip` zip，结构 `{trip.json, trip.gpx, media/<id>.<ext>（仅被该行程引用的）}`
- 导入反向；目标人可选（默认当前人）
- 导出单行程 GPX：单文件 trip.gpx（无图片）

### 8.2 单人整包

- 导出 `.atrip` zip：`{profile.json, life.gpx, trips/<tripId>/..., media/...}`
- 导入时若 personId 已存在 → 询问"覆盖/合并"（合并走 §7.4 同逻辑）

### 8.3 单人全量 GPX

单文件 GPX，含：全部事件 wpt（含 atrip 扩展）+ 各行程 trk/rte/wpt + 一条"人生轨迹" trk（§4.6）。用于 Google Earth 等外部软件查看完整轨迹。

### 8.4 外部 GPX 导入

解析任意 GPX：tracks → 行程路径，waypoints → 行程地点（timePrecision 等扩展缺失按精确日期处理）；自动归入新行程或用户选择目标行程。

## 9. UI 结构与路由

```
/people               人列表（增删、整包导入导出）
/person/<id>/map      主地图（图层开关、搜索框、绘制模式、选中弹卡；安卓含蓝点/记录浮层/回位按钮）
/person/<id>/timeline 时间线
/person/<id>/stats    统计
/trips/<tripId>       行程详情（分组列表、照片墙、编辑）
/edit/...             各类编辑页/编辑模式（在地图页内为主）
/settings             设置：瓦片源URL（保存即时生效、可清缓存）、同步服务器开关/端口/IP、数据目录、关于
```

导航：人列表进入后底部导航（地图/时间线/统计）；编辑以地图内交互为主，详情页为辅。
轨迹记录入口并入地图页（左上角按钮），无独立 /record 页。

## 10. 实施顺序（里程碑与验收标准）

**M1 骨架与存储层** ✅ 已完成
- Flutter 项目（windows+android）、目录结构、Riverpod 初始化
- 数据模型类 + GPX 读写（含全部 atrip 扩展）+ life.gpx 整文件读写 + 媒体池 + 备份目录
- 单测：GPX round-trip、扩展字段读写、事件移入移出、备份逻辑
- 验收：单测全绿

**M2 地图与编辑** ✅ 已完成
- flutter_map + 瓦片缓存、图层开关、点击弹卡
- 地点/路径/事件/行程的增删改（含顶点编辑）、地址搜索（Photon）
- 时间线视图、人生轨迹线（连线规则 + 实/虚线）、统计计算
- 验收：手工全流程可用

**M3 详情与媒体** ✅ 已完成
- 行程详情、照片墙、封面、图片上传/删除
- 验收：图片可见、导出引用正确

**M4 安卓定位** ✅ 已完成
- Kotlin 前台服务插件、采样、记录页、停止保存为 trk
- 实测验收：真机从 A 到 B 记录，轨迹生成且可编辑（详见 §6.6 实现标注）

**M5 局域网同步**
- Windows 服务器 API、Android 客户端、合并逻辑、备份与恢复 UI
- 验收：两端增删改后互相同步，并集无丢失，冲突备份可恢复

**M6 导入导出与打磨**
- 全部导入导出、多人管理、设置项、异常提示
- 验收：全量 GPX 在 Google Earth 打开正确；.atrip 换机导入无损

## 11. 测试策略

- 单元测试（dart test）覆盖：GPX 解析/生成 round-trip（含扩展）、人生轨迹线连线规则与排序、里程统计、同步合并逻辑（含墓碑/冲突）、备份恢复
- 手工验收：按里程碑清单在 Windows 与 Android 真机上执行
- 不写 UI 自动化测试（预算有限，手工清单为准）

## 12. 风险与边界（已知并接受）

- 折线顶点编辑自实现，工作量集中在 M2，退路：编辑模式重新绘制
- Nominatim 无 key 有速率限制：设 User-Agent、失败重试提示，接口收敛可换服务
- Android 厂商省电策略可能杀后台：前台服务 + 电池白名单请求，README/设置中说明
- 人生轨迹线为派生视图，量大时（数千点）渲染用简化抽稀（Douglas-Peucker，阈值按缩放级别），保证流畅
- 跨人引用起终点不支持（选择器只列同人事件）

## 13. 实现偏差与注意事项（开发过程中记录）

- **release APK 必须显式声明 INTERNET 权限**：Flutter 只在 debug/profile 构建自动注入 INTERNET，release 不会，缺了地图瓦片/搜索全部加载失败（曾踩坑）
- **瓦片无数据区域降级（未实施）**：flutter_map 8 对"加载中/未加载"瓦片会自动用低 zoom 祖先瓦片兜底，但对**加载失败**（404/无数据）的瓦片不兜底（灰块）。可行方案已验证：`TileLayer.errorTileCallback` 中逐级取祖先瓦片，替换 `tile.imageInfo` + `notifyListeners`（RawImage BoxFit.fill 自动拉伸，即简单放大）；Esri 无数据区域返回 404 走该路径，完全离线且低 zoom 无缓存时保持灰块。待用户确认后实施
- **瓦片源选择**：Esri（墙内可用，国内部分区域高等级无数据）、OSM（需墙外）、Carto Voyager（实测墙内可用且部分区域放大等级更高）；保存即时生效（invalidate tileUrlProvider），设置页有"清除瓦片缓存"按钮；无数据时提示用户更换瓦片源
- **版本号规则**：`version: 1.0.x+buildNumber`，每次发版 versionName 最后一位自增、buildNumber 同步递增（Android 覆盖安装强校验 versionCode 必须单调增大）
- **安卓构建环境**：本机 Android SDK 位于 `D:\Android\sdk`；gradle Kotlin 增量缓存冲突（Could not close incremental caches）已通过 `org.gradle.parallel=false` + `kotlin.incremental=false`（android/gradle.properties）解决；墙内镜像已配（aliyun/tencent gradle wrapper）
- **真机测试流程**：手机（红米 Note 12 Turbo）开发者选项的"USB 安装"需登录小米账号不可用 → 用 `adb push` + 手机文件管理器手动安装；签名变化（如 debug→release）需先卸载重装；adb 在 `D:\Android\sdk\platform-tools\adb.exe`
