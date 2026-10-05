# screen2gif

把 macOS 屏幕操作变成精简 GIF：**录屏 → 只保留真正变化的关键帧 → 裁掉静止的无关区域 → 调色板编码**。

一段 12 秒、含大量静止等待的 4K 录屏，通常能压成 900px 宽、几十帧、1MB 左右的 GIF，且画面里只剩动过的部分。

## 依赖

- macOS（用系统自带 `screencapture` 录屏）
- ffmpeg / ffprobe：`brew install ffmpeg`
- Node.js ≥ 18（仅用标准库，无 npm 依赖）
- 「屏幕录制」权限：系统设置 → 隐私与安全性 → 屏幕录制，勾选运行命令的终端 / Qoder

## 安装

无需安装。直接调用：

```sh
~/Developer/screen2gif/bin/screen2gif doctor     # 自检依赖与权限
~/Developer/screen2gif/bin/screen2gif record -d 8 -o demo.gif
```

想全局可用：`ln -s ~/Developer/screen2gif/bin/screen2gif /opt/homebrew/bin/screen2gif`，或在 shell 里 `alias s2g='~/Developer/screen2gif/bin/screen2gif'`

## 快速上手

```sh
s2g record -d 8 -o demo.gif              # 录 8 秒并出图
s2g record -o demo.gif                   # 交互终端：Enter 开始 → Enter 停止
s2g record -I -o demo.gif                # 用 macOS 原生工具条，菜单栏按钮停止
s2g record --region window -d 6 -o d.gif # 只录前台窗口
s2g convert 已有录屏.mov -o demo.gif      # 转已有视频
s2g convert in.mov -o d.gif --crop off   # 不裁剪
s2g convert in.mov -o d.gif --crop 200,100,1600,1000
```

## 开始与结束

三种控制方式，都有倒计时和提示音（每秒一声 Tink，开始一声 Glass，结束一声 Tink）：

| 方式 | 开始 | 结束 |
|---|---|---|
| `-d <秒>` | 倒计时后自动 | 到时自动 |
| 手动（默认，需 TTY） | 终端按 Enter | 终端再按 Enter，或 Ctrl-C |
| `-I, --interactive` | 倒计时后自动开始，同时弹出原生录制工具条 | 菜单栏停止按钮（任何 App 里都能点），或终端 Enter / Ctrl-C |

`--countdown 0` 跳过倒计时，`--silent` 关闭提示音。Ctrl-C 走的是同一条停止路径，会正常写完文件并继续转码。`-I` 的时长由停止按钮决定，所以不能与 `-d` 同用；`--region` 仍然有效。

## 管线是怎么工作的

1. **录屏**：`screencapture -v` 产出 4K VFR 的 .mov。定时用 `-V`，手动停止发 SIGINT（screencapture 只在收到 SIGINT 时才写完 moov atom）。`-I` 走 `screencapture -J video`，即系统自带的录制工具条，因此能在菜单栏点按钮停止。
2. **关键帧**：`mpdecimate` 丢弃与上一保留帧几乎相同的帧（变化检测），再用 `select` 按 `1/--fps` 设最小间隔。屏幕录制的整帧 `scene` 分数天然极低（一行文字只改 ~1% 像素），所以不用它做主判据。
3. **自动裁剪**：把关键帧解码成 PNG 后做相邻帧差分 + 噪声门限 + `cropdetect`，得到所有运动的包围盒，换算回源分辨率并留白。
   注意：差分**不能**直接在 .mov 上做——`tblend` 对 screencapture 的流会给出恒定的假偏移；解码成 PNG 后差分才准确。
4. **编码**：关键帧 PNG 按各自时间间隔写成 concat 清单，`palettegen` + `paletteuse` 两遍编码（比单遍小一个数量级），`-loop 0` 无限循环。

## 参数

见 `s2g --help`。要点：

- `--sensitivity low|default|high`：`mpdecimate` 档位。4K 录屏每帧都带压缩噪声，ffmpeg 面向电影的默认值在这里反而是最不敏感的一档。
- `--crop auto|off|x,y,w,h`：`auto` 检测运动包围盒；运动覆盖全画面时自动退化为不裁剪。
- `--region screen|window|x,y,w,h`：录制范围，单位是屏幕点（录屏输出为 2 倍像素）。
- `--max-gap`：单帧最长停留，把长静默截断，避免 GIF 看起来卡死。
- `--keep-frames` / `--keep-mov`：保留中间产物供检查。

## 故障排查

| 现象 | 原因与处理 |
|---|---|
| 录屏文件只有几 KB | 缺屏幕录制权限，按报错里的路径授权 |
| 录制进程不结束、无输出 | 录屏会话卡死（通常因上次录制被 `kill -9`）。`killall ControlCenter` 或注销恢复 |
| `--region window` 报错 | 前台应用不向 System Events 暴露窗口，改用 `--region x,y,w,h` |
| 关键帧只有几帧 | 画面确实没怎么动；或 `--sensitivity` 太低 |
| GIF 体积大 | 降 `--width` / `--fps` / `--max-frames`；确认没加 `--no-palette` |

## 原生菜单栏 app（人在电脑前时更好用）

`native/` 里是一个 SwiftUI 菜单栏 app：点图标选「录制全屏」或「框选区域录制…」（屏幕上拖拽，Esc 取消），也可以直接用全局快捷键。开始和结束各有一声提示音（Glass / Tink），圈选录制时选区外会出现红框（画在选区之外，不会入镜）。录完自动调用本仓库的 CLI 转码并在 Finder 里揭示桌面上的 GIF。采集走 ScreenCaptureKit（`SCRecordingOutput` 直接写 .mov），区域用 `SCStreamConfiguration.sourceRect` 裁（注意它是所选显示器自己的逻辑坐标系）。圈选录制转码时自动加 `--crop off`——圈选已经表达了取景意图，不再做运动区域裁剪；全屏录制保留 `--crop auto`。

### 录制状态条

录制中屏幕顶部会出现一条深色胶囊状态条（全屏和框选共用同一套）：红色 REC 圆点每秒闪烁、等宽数字计时、右侧「停止」按钮点一下即停——不用再去找菜单栏图标。它对鼠标点击生效但**不抢焦点**（nonactivating panel），点停止不会把正在演示的应用晃出去。框选时状态条在选区正上方（选区外，天然不入镜；选区贴屏幕顶时移入选区内）；全屏时在主屏顶部菜单栏下方，靠 `SCContentFilter(excludingWindows:)` 从采集里剔除，**不会被录进成片**。

框选录制时选区四周是四个细角标（取景框风，白色 halo + 深灰主线，深浅背景都清晰），不画边、中间零遮挡。框选开始的一瞬间角标从外围收拢到位并闪一下——像相机对焦，「对焦清晰 = 录制开始」，Glass 提示音同步在收拢完成时响起。

### 全局快捷键

| 动作 | 默认 | 可改 |
|---|---|---|
| 录制全屏 | ⇧⌘6 | 菜单 → 快捷键设置… |
| 框选区域录制 | ⇧⌘7 | 同上 |
| 停止录制 | ⇧⌘8 | 同上 |

默认排在系统截屏键 ⇧⌘5 后面。设置窗口里点击条目即可录入新组合（需含 ⌘/⌃/⌥ 之一，⌫ 禁用，Esc 取消），改完即存即生效，无需重启。实现走 Carbon `RegisterEventHotKey`（系统级热键，无需辅助功能权限）；冲突时注册失败，换个组合即可。

```sh
cd native && ./build.sh && open build/screen2gif.app
```

注意：屏幕录制权限归属这个 .app，而且系统不会主动弹授权框（菜单栏 agent + 本地签名），必须手动加一次：系统设置 → 隐私与安全性 → 屏幕与系统录音 → `+`，选 `native/build/screen2gif.app`；没授权时菜单里会出现「打开屏幕录制设置…」。`build.sh` 用自签名证书 `screen2gif Dev`（login keychain 中受信任的代码签名根）签名，designated requirement 只认 bundle id + 证书哈希，所以重建不会掉授权；证书若丢失，脚本会退回 ad-hoc 并告警，那时每次重建都得重新授权。构建还依赖 `~/Developer/.swift-sdk-fix/` 的工具链补丁（原因见 `native/build.sh` 头部注释）。agent 调用仍走 CLI。

## 目录

```
bin/screen2gif   CLI 入口与参数解析
lib/record.mjs   screencapture 封装（定时/手动停止、看门狗、窗口区域）
lib/video.mjs    ffprobe 探测、关键帧抽取、运动包围盒、GIF 编码
native/          菜单栏 app（ScreenCaptureKit 采集 + 框选 overlay + 调 CLI 转码）
SKILL.md         给 Qoder 的技能说明
```
