# 探索的时光 Adventuring Time

纯本地的足迹地图应用，用于记录一个人的一生轨迹：在哪里生活（长期地点）、去过哪里（行程与地点）、走过什么路（路径）、人生如何展开（时间线与轨迹线）。所有数据保存在本机，格式开放（GPX + 扩展字段），不依赖任何云服务。

## 功能

- **地图**（flutter_map）：图层开关（地点/长期地点/路径/轨迹线）、地址搜索（Photon，结果数字标注选点）、点击地图落点并自动反向地理编码填名称
- **长期地点**：人生轨迹节点（出生地/家/学校/公司），必填到达时间，支持年/月/日精度；参与时间线与轨迹线；可移入/移出行程
- **行程**：一段旅行，包含路径（GPS 轨迹或手绘）、打卡地点、封面、起终点长期地点引用；行程连接线可点击打开行程卡片
- **路径**：GPS 轨迹导入或地图手绘（点击落点、完成按钮结束），支持顶点编辑、整体平移、编辑信息（名称/说明/时间/附图）与删除
- **人生轨迹线**：长期地点与行程按时间排序相连，行程内路径/地点/起终点按时间顺序连线并连回终点；实线=实际记录段，虚线=推算直线段
- **时间线**：长期地点与行程混合排序展示，点击直接编辑
- **统计**：记录里程/推算里程/长期地点/行程/照片
- **媒体**：地点/路径/行程封面可附图，照片墙浏览

## 技术栈

- Flutter（Windows 桌面 + Android），Riverpod 状态管理
- flutter_map 8.x + Esri 瓦片（墙内可用，WGS-84 无偏移；OSM 可在设置切换）
- 地址搜索/反向地理编码：Photon（https://photon.komoot.io/）
- 数据存储：GPX 文件 + JSON 元数据（见下文）

## 数据存储

默认数据根目录：`%USERPROFILE%\AdventuringTime\data`

```
data/people/<personId>/
├── profile.json        # 个人信息
├── life.gpx            # 长期地点（人生轨迹节点）
├── media/              # 图片池（mediaId 引用）
├── trips/<tripId>/
│   ├── trip.json       # 行程元数据（名称/说明/日期/起终点/封面）
│   └── trip.gpx        # 行程内容（wpt 地点 + trk/rte 路径）
└── backups/            # 每次写入前的自动备份
```

GPX 扩展：`isEvent`（长期地点，atrip:eventType=life）、`timePrecision`（年/月/日）、起终点引用等写入 GPX 扩展字段。所有写入先备份再落盘。

## 构建与运行

```bash
flutter pub get
flutter test          # 19 个测试（模型/GPX/存储/生命周期/时间线）
flutter run -d windows
flutter build windows --release   # 产物 build\windows\x64\runner\Release\adventuring_time.exe
```

开发环境细节与自动化测试入口见 [AGENTS.md](AGENTS.md)。
