# Adventuring Time v1.1.10

探索的时光：纯本地足迹地图应用。数据全本地（GPX + JSON），无云服务。

## v1.1.10（2026-08-07）

- 覆盖导入改为先备份再替换：导入 .atrip 整包选择"覆盖"时，原数据先进该人物的备份（`backups/<ts>-overwrite`），可随时从设置页备份管理恢复
- 移除 data/trash 回收目录逻辑，数据保险统一走 backups 机制

## v1.1.9（2026-08-07）

- 修复跨 180° 经线连线点不到：点击检测对齐 world 翻转与相邻副本
- 删除地点/路径后清理孤儿媒体
- 统计页媒体数按实际引用计数

## 下载

- Windows 安装包：`adventuring_time_setup_1.1.10.exe`
- Android APK：`adventuring_time_1.1.10.apk`（versionCode 15，可覆盖安装 1.1.9）
