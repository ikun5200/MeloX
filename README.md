# MeloX · QQ 音乐迁移版

[简体中文](README.md) | [English](README.en.md)

MeloX 是一个使用原生 SwiftUI 构建的第三方音乐播放器。本仓库是
[youshen2/MeloX](https://github.com/youshen2/MeloX) 的个人迁移分支：iOS 端的
网易云音乐后端已替换为 QQ 音乐，播放与下载地址由用户自行导入的洛雪（LX）音源解析。

> 本项目是非官方开源项目，与 QQ 音乐、腾讯及其关联公司不存在隶属、合作或授权关系。
> 项目不内置任何音源、密钥或会员内容，也不提供绕过付费/版权限制的能力。

## 当前状态

| 平台 | 状态 |
| --- | --- |
| iPhone / iPad | QQ 音乐主流程已完成 |
| Apple Watch | 仍为网易云实现，待迁移 |
| macOS（MeloX Desktop） | 仍为网易云实现，待迁移 |

网易云原版代码保留在 `netease-final` 快照分支，便于对照与回退。
当前默认分支为 `qq-migration`。

## 功能

- **QQ 音乐浏览**：搜索与联想、歌曲/专辑/歌手/歌单/榜单详情、推荐歌单、新碟、评论。
- **QQ 登录**：QQ 扫码、微信扫码、手机验证码；匿名可浏览，收藏等操作再提示登录。
- **音乐库**：我喜欢的音乐、自建/收藏歌单、收藏专辑、关注歌手，以及喜欢/收藏/创建/删除/增删歌曲。
- **洛雪音源**：
  - 粘贴 `lx` 源 URL、导入本地 `.js`、导入 LX 源列表/订阅；
  - 多源优先级、启用/禁用、失败自动切换；
  - 自动识别源声明的 QQ（`tx`）音质，并按 7 档音质自动降级；
  - 源脚本在设备端 JavaScriptCore 中执行，不上传到服务器；
  - 源地址与密钥不会写入仓库，也不会内置到 App。
- **播放/下载**：完全由洛雪源解析地址，支持请求头、下载、失败提示并自动跳下一首。
- **MV**：歌曲详情页可打开 MV 并播放。
- **歌手增强**：歌手简介、相似歌手。
- **歌词**：QQ 音乐 QRC 逐字歌词 / LRC、翻译与罗马音；保留 Apple Music 风格动效。
- **首页/发现**：QQ 推荐歌单、榜单、新碟；每日推荐/私人 FM/心动模式用 QQ 榜单近似。
- **已删除**：播客、音乐云盘、听歌识曲、歌曲百科、听歌排行、私信、一起听入口、
  转发动态、网易云深链识别及其页面/模型/权限。

## 下载与安装

最新构建发布在 Releases 的滚动页面：

- [MeloX iOS 开发版（最新构建）](https://github.com/ikun5200/MeloX/releases/tag/ios-latest)

资产名：`MeloX-iOS-unsigned.ipa`。

该 IPA **未签名**，不能直接安装。请使用自己的证书/描述文件签名，或通过
AltStore、SideStore、TrollStore 等工具安装。每次 `qq-migration` 分支构建成功后，
该 Release 会自动更新。

GitHub Actions 每次构建也会保留 14 天的 artifact：
`MeloX-iOS-unsigned-<run_number>`。

## 首次使用

1. **导入音源**：设置 → 洛雪源 → 粘贴你自己的 `lx` 音源 URL，或导入本地 `.js` / 源列表。
   只启用包含 QQ 音乐（`tx`）的源；其他平台会被标记为不支持。
2. **登录（可选）**：设置 → QQ 音乐账号 → QQ 扫码 / 微信扫码 / 手机验证码。
   匿名也可以搜索和播放；收藏、歌单等操作需要登录。
3. **播放**：搜索或首页选歌。播放页显示实际解析到的音质；源不支持请求档位时会自动降级。
4. **下载**：歌曲/专辑/歌单菜单选择音质下载，下载同样走音源解析。

> 音源由你自行提供并承担合规责任。项目不会内置、分发或推荐任何具体音源。

## 从源码构建

要求：

- Xcode 27.1 或更高版本
- iOS 27.1 SDK
- 可用的 macOS 构建环境

```bash
git clone https://github.com/ikun5200/MeloX.git
cd MeloX
bash build_ios_unsigned.sh
```

产物：`build/MeloX-iOS-unsigned.ipa`（未签名）。

### CI

`.github/workflows/build-ipa.yml` 在以下情况运行：

- 推送到 `qq-migration` 或 `main`
- 手动 `workflow_dispatch`
- 推送 `v*` 标签

流程：

1. 运行 `Tools/Tests/test_qq_backend.py` 后端离线检查；
2. 构建未签名 IPA；
3. 上传 Actions artifact；
4. 自动创建/更新 `ios-latest` Release；
5. `v*` 标签额外创建对应版本 Release。

后端检查覆盖：QQ `zzc` 签名、音质映射、搜索/歌单解析、QQ 分享链接解析、
LX 运行时初始化与播放地址解析。

## 目录结构

```text
MeloX/
  App/                    应用入口、导航、播放器展示
  Core/Backend/QQ/        QQ 音乐 CGI 客户端、登录、模型、映射
  Core/Sources/           洛雪源存储、JavaScriptCore 运行时、音质映射、解析器
  Core/Playback/          播放队列、引擎、AutoMix、会话
  Core/Lyrics/            QQ 歌词、QRC 解码、AMLL 合并
  Features/               搜索、首页、音乐库、歌单、专辑、歌手、MV、设置等
  Resources/LX/           LX 运行时 preload（不含任何具体音源）
Tools/Tests/              后端离线检查与模拟器启动冒烟脚本
```

## 已知限制

- 桌面端与 Watch 尚未迁移到 QQ 音乐。
- QQ 音乐库写操作已按 QQMusicApi 协议接入，但仍建议用真实账号回归一轮。
- 每日推荐/私人 FM/心动模式是 QQ 榜单近似，不是官方个性化推荐。
- 没有独立的 MV 浏览页；MV 入口在歌曲详情页。
- 模拟器启动冒烟脚本已提供（`Tools/Tests/simulator_smoke.sh`），
  但 GitHub Actions runner 上模拟器构建耗时过长，暂未挂入 CI。
- 音源兼容性取决于脚本本身；使用 Node API 的 LX 源会显示为不兼容。

## 安全与合规

- 音源配置以明文保存在本机 Application Support，便于调试与迁移；请勿在共享设备上使用。
- 源脚本按不可信代码处理：运行在受限 JavaScriptCore 环境，网络请求有超时与大小限制。
- 本项目仅用于学习与研究。请遵守所在地法律法规、QQ 音乐服务条款及音乐版权要求。
- 下载后请于 24 小时内删除。

## 致谢

- 上游项目：[youshen2/MeloX](https://github.com/youshen2/MeloX)
- QQ 接口参考：[L-1124/QQMusicApi](https://github.com/L-1124/QQMusicApi)
- 洛雪音乐自定义源协议：LX Music
- 歌词/播放器相关参考项目与许可信息见应用内“项目与许可”页面

## 许可

主体代码遵循 GPLv3。第三方代码、资源、字体、模型与 PV Tool 相关内容仍按各自许可证使用，
详见 [LICENSE](LICENSE) 与 `MeloX/Resources/` 下的许可文件。
