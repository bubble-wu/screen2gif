---
name: screen2gif
description: 录制 macOS 屏幕操作并产出精简 GIF：自动抽取关键帧、裁掉画面中静止的无关区域、调色板编码控制体积。当用户要录屏转 GIF、做操作演示动图、截取操作关键帧时使用。
---

# screen2gif

把一段屏幕操作变成小而准的 GIF：录屏 → 只保留画面真正变化的关键帧 → 裁掉周围静止区域 → 调色板两遍编码。

CLI 位置：`~/Developer/screen2gif/bin/screen2gif`（下称 `s2g`）。依赖 ffmpeg（`brew install ffmpeg`）与系统自带 `screencapture`。

用户在电脑前想自己点着录时，另有菜单栏 app（`native/`，用法见 README）；**agent 一律走 CLI**，因为 app 需要人手动授权且靠鼠标点菜单。

## 何时用

- 用户要「录一段操作做成 GIF / 动图 / 演示图」
- 已有录屏文件（.mov/.mp4）要压成 GIF
- 需要「只保留关键步骤画面」的精简动图，而不是逐帧视频

## 标准流程

1. 先跑 `s2g doctor` 确认依赖与屏幕录制权限（首次或报错时）。
2. 录制并出图：
   - 非交互环境（agent 调用）**必须**带 `-d <秒>`，否则无法按 Enter 停止：
     `s2g record -d 8 -o demo.gif`
   - 交互终端可省略 `-d`：按 Enter 开始 → 倒计时 → 再按 Enter 停止。
   - 用户自己在电脑上操作、希望在任意 App 里用按钮结束：`s2g record -I -o demo.gif`
     （macOS 原生录制工具条，屏幕上选区域，菜单栏停止按钮结束）。
3. 已有视频直接转：`s2g convert 录屏.mov -o demo.gif`

录制期间需要画面真的在动（打字、滚动、拖窗口），否则关键帧会很少。若要在录制时演示操作，用后台子进程驱动（AppleScript 按键/移动窗口），录制命令本身占住前台。

## 开始 / 结束的控制方式

| 方式 | 开始 | 结束 | 适用 |
|---|---|---|---|
| `-d <秒>` | 倒计时后自动 | 到时自动 | agent 调用、脚本 |
| 手动（默认，需 TTY） | 终端按 Enter | 终端再按 Enter 或 Ctrl-C | 人在终端前 |
| `-I, --interactive` | 倒计时后自动开始，同时弹出原生工具条 | 菜单栏停止按钮 / 终端 Enter / Ctrl-C | 要离开终端在别的 App 里操作 |

提醒：倒计时每秒打印 `3… 2… 1…` 并有轻提示音，开始录制一声 Glass，结束一声 Tink；`--countdown 0` 取消倒计时，`--silent` 关掉全部提示音。Ctrl-C 同样会正常收尾并继续转码，不会丢文件。

## 常用参数

| 参数 | 作用 | 默认 |
|---|---|---|
| `-o, --out` | 输出 GIF 路径 | `./s2g-<时间戳>.gif` |
| `-w, --width` | 输出宽度（0 = 不缩放） | 900 |
| `-d, --duration` | 定时录制秒数 | 手动 Enter 停止 |
| `-I, --interactive` | 用 macOS 原生录制工具条，菜单栏按钮停止 | 关 |
| `--countdown` | 开始前倒计时秒数（0 = 直接开始） | 3 |
| `--silent` | 关闭提示音 | 关 |
| `--fps` | 关键帧率上限 | 10 |
| `--sensitivity` | 变化检测灵敏度 `low/default/high` | default |
| `--crop` | `auto` / `off` / `x,y,w,h` | auto |
| `--region` | 录制范围 `screen` / `window` / `x,y,w,h`（屏幕点） | screen |
| `--clicks` | 高亮鼠标点击 | 关 |
| `--max-frames` | 关键帧上限，超出均匀抽稀 | 240 |
| `--keep-frames` | 保留关键帧 PNG 供检查 | 关 |
| `-q` | 只输出结果路径（便于脚本取用） | 关 |

## 调优直觉

- GIF 太大：降 `--width`（600 通常足够）、降 `--fps`、降 `--max-frames`。
- 动作被漏掉 / 帧太少：`--sensitivity high`。
- 帧太碎 / 体积大：`--sensitivity low`。
- 裁剪裁掉了想保留的上下文：`--crop off` 或加大 `--pad`。
- 想确认抽了哪些帧：加 `--keep-frames`，检查 PNG 目录。

## 已知坑（重要）

- **不要用 `kill -9` 中断录制。** 被强杀的 screencapture 会泄漏录屏会话，导致之后所有录制静默挂死。CLI 内部已用 SIGINT→SIGTERM→SIGKILL 阶梯停止并带看门狗；人工干预时请按 Enter 或 Ctrl-C。
- 若录制已卡死（screencapture 进程不响应、无输出）：重启 ControlCenter（`killall ControlCenter`，菜单栏图标会闪一下并自动恢复）或注销登录。
- `--region window` 依赖 System Events 读取前台窗口；部分应用（Obsidian 等）不暴露窗口，会报错并提示改用 `--region x,y,w,h`。
- `-I` 会立即开始录制，时长由菜单栏停止按钮决定，因此不能与 `-d` 同用（CLI 会直接报错）；区域仍可用 `--region` 指定。
- 屏幕录制权限缺失时录出的文件只有几 KB，CLI 会明确报错并给出设置路径。

## 输出解读

成功时 stderr 打印：源信息、裁剪结果（`auto WxH+X+Y` 或「运动覆盖全画面，不裁剪」）、关键帧数与 GIF 时长、最终路径与体积。`-q` 时 stdout 只有一行输出路径。
