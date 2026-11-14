# Release 流程

发布版本以 `pubspec.yaml` 的 versionName 为准（如 `1.2.12`），tag 为 `v<versionName>`。

## 1. 先判断要不要重新编译

工作区干净且与远程同步（`git status` 无改动、`HEAD` 与上游一致）时，如果本次发布的功能已编译过、产物还在，就**不要重新编译**，只做：

1. 核对版本号一致（见第 2 节）
2. 确认产物存在，给出路径（见第 4 节）
3. 打 tag 并推送（见第 5 节）

只有代码有改动或产物缺失/过期时才走完整构建（第 3 节）。

## 2. 版本号三处一致

| 位置 | 字段 | 示例 |
|---|---|---|
| `pubspec.yaml` | `version` | `1.2.12+50` |
| `lib/version.dart` | `appVersion` | `1.2.12` |
| `windows/installer/setup.iss` | `MyAppVersion` | `1.2.12` |

`build-apk` 由 devtool 自增（versionName 末位 +1、buildNumber 同步 +1），主 agent 不预先改。

## 3. 完整构建（仅在需要时）

按顺序交给 devtool：`test`、`build-windows`、`build-apk`，再本地生成 Windows 安装包：

```powershell
& "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe" windows\installer\setup.iss
```

生成前确保 `setup.iss` 的 `MyAppVersion` 已是本次版本。

## 4. 产物与交付

只需两个文件：

- Android：`build\app\outputs\flutter-apk\app-release.apk`
- Windows：`build\installer\adventuring_time_setup_<version>.exe`

回复中直接给出这两条路径即可，不必打包 zip、不必复制到别处、不必推手机（除非明确要求）。

## 5. 打 tag 与推送

1. devtool `commit`：提交版本号相关改动（`pubspec.yaml`、`lib/version.dart`、`setup.iss`）
2. 打 tag：`git tag v<version>`
3. devtool `push-gh`：`git push origin master v<version>`

推送失败就停下，等用户开梯子后重试，不自行配置代理。

## 6. Release 说明格式

GitHub Release 的标题（Release title）为 `vX.Y.Z - 更新标题`，更新标题用一句话概括本次主要更新内容（如「经纬线与定位跳转」）；说明正文的一级标题只写 `# vX.Y.Z`，不加副标题。正文按「新功能 / 改进 / 修复」分节，每条一句话、动词开头、说清具体行为；最后「下载」列出两个安装包文件名。无内容的节省略。

只写发布后用户可感知的最终行为与限制，不写中间过程、返工说明等（如「跨 180° 经线正常绘制」这类修补细节）；专门说明修复的 bug 除外，「修复」分节可写具体问题与表现。

```markdown
# vX.Y.Z

## 新功能

- 功能点，说清入口与效果

## 改进

- 行为调整

## 修复

- 修复的问题与表现

## 下载

- Windows：`adventuring_time_setup_X.Y.Z.exe`
- Android：`adventuring_time_X.Y.Z.apk`
```

示例（v1.2.12，Release 标题 `v1.2.12 - 经纬线与定位跳转`）：

```markdown
# v1.2.12

## 新功能

- 地图经纬度网格：设置页「地图叠加」新增开关，网格步长随缩放自适应并标注度数，深色模式适配
- 瓦片缓存自动更新：设置页新增开关，更换瓦片源后浏览到其他来源的缓存瓦片时自动重下覆盖，无需清空全部缓存
- 跳转地图定位：长期地点、行程详情页与地点/路径弹卡可直接跳到地图并选中定位，自动打开对应图层，地图缩放到完整可见
- 地图选中高亮：选中行程时高亮整条行程（路径、连接线与地点），选中地点时高亮该地点标记
- 行程详情照片墙：汇总行程内路径与地点的照片，预览时标注来源并可跳转编辑

## 改进

- 地图缩放范围限定 0.5–22 级；Ctrl+单击复位正北
- 行程/长期地点详情页的删除按钮移到页面底部

## 下载

- Windows：`adventuring_time_setup_1.2.12.exe`
- Android：`adventuring_time_1.2.12.apk`
```

说明文字在回复正文中给出，不另存文件。
