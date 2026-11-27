# MeloX Release Notes / MeloX 更新日志

## iOS + Apple Watch

### 简体中文

- 2.1.5：设置新增「首页排版」，在预览里直接拖动栏目和快捷入口排序，调整横向卡片/网格、卡片大小和显示隐藏，保存后才应用到首页。
- 收藏歌曲支持多选批量加入歌单、加入播放队列、下一首播放、下载和取消收藏；取消收藏先确认，失败的项目保留选中并提示。
- 收藏歌曲支持调整顺序，排序按账号保存在本机，重新登录仍保留，不改变 QQ 客户端的排序。
- 收藏列表不再只读取前一批歌曲，会继续分页读取；未完整读取前不会把已加载内容当成全部收藏。
- 修复音乐库歌手列表报「音乐服务返回了错误（1,000）」：现在会识别登录过期并自动续期一次；续期失败时保留已有音乐库内容，并直接提供「重新登录」。
- 2.1.4：播放页底部中间的按钮改为隔空投送（AirPlay），可直接把播放送到其他设备；悬浮歌词开关移入封面右上角的「…」菜单。
- 调节进度条或音量后，底部控制面板会在几秒后自动淡出，轻点面板区域即可重新显示。
- 2.1.3：新增「播放诊断」（设置 → 关于 → 开发者选项 → 播放诊断）。可查看当前歌曲与音质证据、音源实际交付的格式，以及两路播放器的采样率、声道、缓冲、音频会话与输出路由，支持一键复制全文。
- 2.1.2：播放音质按当前音源实际返回的文件判定；QQ 资料漏报某一档不会限制尝试。「未检测」不再写成「本曲暂无」，降档只影响当前歌曲。
- 普通播放在曲尾提前约 60 秒选好并缓冲下一首。切歌复用已完成或正在进行的请求；预取失败不会提前停止当前歌曲。

- 发现页推荐行按当前窗口宽度排满完整卡片，与下方网格的左右边缘对齐；长短标题歌单的封面统一按顶边排列

- 参照 Apple Music 实机界面收紧侧栏顶部空间，搜索置顶，账号入口固定在侧栏底部，不随列表滚动
- 歌单和专辑页改为左封面、右信息的横向信息头，下方显示整宽歌曲表，宽窗口独立展示歌手和时长

- 发现页参考 Apple Music iPad 的 Top Picks 横向卡片排布，推荐大图限制为窄竖卡片，首屏保留后续内容
- 统一工具栏分享、更多和其他图标的画布与中心，补齐播放按钮高度

- iPad 榜单、歌单和专辑详情限制封面大小，保留随封面变化的背景色，横屏可直接看到歌曲
- 详情页使用紧凑播放按钮，窄窗口以小封面横向展示信息
- 歌词 Widget 的版本号与主应用保持一致

- iPad 使用 Apple Music 风格的原生侧边栏，直接访问音乐库分类，并在宽窗口中显示完整底部播放条
- 调整 iPad 全屏播放器的封面、歌词与队列比例，适配 iOS / iPadOS 27.0.1、旋转和较窄窗口
- 首页封面卡片和音乐库网格按窗口宽度调整尺寸

- 首页每日推荐等快捷入口默认使用更小的紧凑卡片，可在通用设置中切换大小
- 新增首页推荐、音乐库和歌单信息自动缓存，再次打开时优先显示已有内容，网络刷新失败时保留缓存
- 修复了播放队列中播放模式控件吸顶切换时，歌曲列表和滚动指示条位置跳动的问题（感谢 @Fab1e2000）

### English

- 2.1.5 adds Homepage Layout in Settings: drag sections and shortcuts directly in the preview, switch shelves to grids, change card size, and hide or restore items; nothing applies until you save.
- Favorite songs now support batch selection for playlists, the queue, Play Next, downloads, and removal from favorites. Removal asks first and keeps failed items selected with a clear report.
- Favorite songs can be reordered. The order is stored per account on this device and survives signing in again; it does not change the order in the QQ client.
- The favorites list keeps paging instead of stopping at the first batch, and never presents partially loaded content as the whole library.
- Fixed the artist list failing with “the music service returned error (1,000)”. An expired sign-in is now detected and renewed once; if renewal fails, existing library content stays and a Sign In Again action is offered.
- 2.1.4 turns the middle button on the player's bottom row into AirPlay, so playback can be sent to other devices; the Floating Lyrics toggle moved into the “…” menu beside the artwork.
- After adjusting the progress or the volume, the bottom panel fades out a few seconds later; tapping the panel brings it back.
- 2.1.3 adds Playback Diagnostics (Settings → About → Developer Options): the current song, per-tier evidence, the stream a source delivered, both decks' sample rate and channels, and the audio session and output route, with a copy-all button.
- In 2.1.2, playback quality is checked against the file delivered by the source. A tier missing from QQ’s catalog response can still be tried. Unverified tiers are no longer labelled as absent, and falling back does not change the preference for the next song.
- During ordinary playback, MeloX selects and buffers the next track with about 60 seconds remaining. Advancing reuses the prepared track or the ongoing request. Preparation failures do not stop the outgoing track early.

- Fitted complete Discovery feature cards to the current window, aligned the shelf and grid edges, and top-aligned playlist covers despite different title lengths

- Reduced sidebar header whitespace, moved Search to the top and pinned the account entry in the sidebar bottom bar, following Apple Music's iPad layout
- Added a horizontal artwork-and-metadata collection header above a full-width track table, including separate artist and duration columns on wide windows

- Refined Discovery using an Apple Music-inspired horizontal Top Picks shelf, with bounded portrait cards and room for the next section
- Standardized toolbar symbol canvases and centering, and aligned the playback action label height

- Bounded artwork on iPad chart, playlist, and album detail pages so songs are visible immediately, while retaining artwork-derived background colors
- Added compact playback actions, with inline artwork and metadata in narrower windows
- Matched the lyrics Widget version to the main app

- Added an Apple Music-inspired iPad sidebar with library shortcuts and a wider bottom playback accessory
- Refined iPad artwork, lyrics, and queue proportions for iOS / iPadOS 27.0.1, rotation, and resizable windows
- Made home artwork shelves and library grids adapt to the available window width

- Home shortcuts, including Daily Recommendations, now use smaller cards by default, with a compact layout toggle in General settings
- Added automatic caching for home recommendations, library lists, and playlist details, with cached content shown first and preserved when network refreshes fail
- Fixed jumps in the song list and scroll indicator when playback mode controls pin or unpin at the top of the queue (thanks to @Fab1e2000)

## macOS

### 简体中文

- 修复了长歌单滚动时可能卡顿或卡死，以及自动分页加载异常的问题（感谢 @zly2006）
- 收藏歌曲、歌单和专辑详情页的“定位到正在播放”改为右下角常驻悬浮按钮，滚动长列表时也可随时定位
- 修复了迷你播放器切歌后歌词可能停留在上一首的问题，主窗口关闭时也会同步更新歌词
- 修复了全屏歌词页展开系统菜单栏时出现黑色条带或闪烁的问题

### English

- Fixed stuttering or freezes when scrolling through long playlists and issues with automatic page loading (thanks to @zly2006)
- Added a persistent floating “Locate Now Playing” button in the bottom-right corner of Liked Songs, playlist details, and album details, keeping it accessible while scrolling long track lists
- Fixed mini player lyrics getting stuck on the previous song after switching tracks, including when the main window is closed
- Fixed a black strip or flicker when revealing the system menu bar in the full-screen lyrics view
