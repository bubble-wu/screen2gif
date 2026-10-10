# CLI 使用说明

[返回首页](../README.md) · [macOS App 使用说明](macos-app.md)

## 依赖

- macOS（录屏使用系统自带的 `screencapture`；App 要求 macOS 15+）
- Node.js ≥ 18（仅用标准库，无 npm 依赖；没装时运行 CLI 会直接提示 `brew install node`）
- ffmpeg / ffprobe：**不需要提前装**——第一次运行 `record` / `convert` 检测到缺失时，会询问是否现在通过 Homebrew 自动安装（非交互环境给出手动安装命令）
- 「屏幕录制」权限：macOS 把权限授给**运行命令的终端 app**（Terminal / iTerm / Qoder 各自独立，换终端要重新授权）。缺权限时录屏是 0 字节——CLI 会自动打开系统设置的授权面板，并指名该勾选哪个 app

## 安装

需要 Node.js ≥ 18 与 ffmpeg。CLI 没有 npm 依赖，无需运行 `npm install`。下载[源码 ZIP](https://github.com/bubble-wu/screen2gif/archive/refs/heads/main.zip) 并解压，或 clone 仓库后调用：

```sh
git clone https://github.com/bubble-wu/screen2gif.git
cd screen2gif
./bin/screen2gif doctor                  # 自检依赖与权限
./bin/screen2gif record -d 8 -o demo.gif
```

本文后续用 `s2g` 代指 `./bin/screen2gif`。想全局可用：`ln -s "$(pwd)/bin/screen2gif" /opt/homebrew/bin/screen2gif`（在 clone 目录里执行），或在 shell 里 `alias s2g='<clone 路径>/bin/screen2gif'`

### 作为 agent skill 使用

仓库根目录带 `SKILL.md`，可注册给你所用的 agent：把整个目录（或 symlink）放进技能目录，例如 `ln -s "$(pwd)" ~/.agents/skills/screen2gif`。

输出位置：不传 `-o` 时默认存**当前目录**（`s2g-<时间戳>.gif`）；`-o` 也接受目录（已存在或以 `/` 结尾），自动往里放时间戳文件名，`~/` 前缀会展开。菜单栏 app 默认存桌面，在「设置… → 输出位置 → 更改输出文件夹…」中选择。

菜单中的「打开 GIF 存储目录」直接在访达中打开当前输出文件夹。若目录已移动或无法访问，会提示重新选择。

## 快速上手

```sh
s2g record -d 8 -o demo.gif              # 录 8 秒并出图
s2g record -o demo.gif                   # 交互终端：Enter 开始 → Enter 停止
s2g record -I -o demo.gif                # 用 macOS 原生工具条，菜单栏按钮停止
s2g record --region window -d 6 -o d.gif # 只录前台窗口
s2g record --then 'bash 操作脚本.sh' -o d.gif   # 边录边执行命令，命令结束即停
s2g convert 已有录屏.mov -o demo.gif      # 转已有视频
s2g convert in.mov -o d.gif --crop off   # 不裁剪
s2g convert in.mov -o d.gif --crop 200,100,1600,1000
```

## 开始与结束

四种控制方式，都有倒计时和提示音（每秒一声 Tink，开始一声 Glass，结束一声 Tink）：

| 方式 | 开始 | 结束 |
|---|---|---|
| `-d <秒>` | 倒计时后自动 | 到时自动 |
| `--then '<命令>'` | 立即（倒计时默认 0） | 命令（交 `sh -c`，输出透传）退出即停 |
| 手动（默认，需 TTY） | 终端按 Enter | 终端再按 Enter，或 Ctrl-C |
| `-I, --interactive` | 倒计时后自动开始，同时弹出原生录制工具条 | 菜单栏停止按钮（任何 App 里都能点），或终端 Enter / Ctrl-C |

`--countdown 0` 跳过倒计时，`--silent` 关闭提示音。Ctrl-C 走的是同一条停止路径，会正常写完文件并继续转码。`-I` 的时长由停止按钮决定，所以不能与 `-d` 同用；`--then` 的时长由命令决定，不能与 `-d` / `-I` 同用，命令退出码非 0 时仍会出图（ stderr 给警告——失败的操作过程往往正是要看的）；`--region` 在两者下都有效。

### 给 agent / 脚本：自动化编排

让程序驱动屏幕操作并录下来，两种范式：

```sh
# 范式一：--then 一条龙（首选）——真正开录后才执行命令，命令退出即停
s2g record --then 'bash drive-ops.sh' --json -o demo.gif

# 范式二：外部编排——--ready-file 在 screencapture 拉起那一刻才创建
# （距实际出画约百毫秒，通常无感），等它出现再动手，操作不会被倒计时吞掉开头
#（每次使用独立目录，避免误读上次残留信号）
S2G_READY_DIR=$(mktemp -d /tmp/s2g-ready.XXXXXX)
s2g record -d 15 --countdown 0 --ready-file "$S2G_READY_DIR/ready" -o demo.gif &
S2G_PID=$!
while [ ! -f "$S2G_READY_DIR/ready" ] && kill -0 "$S2G_PID" 2>/dev/null; do
  sleep 0.2
done
if [ -f "$S2G_READY_DIR/ready" ]; then
  # ……执行要被录下来的操作……
  :
fi
wait "$S2G_PID"
```

`--json` 成功时在 stdout 输出单行结果（`gif` 路径、`bytes`、`frames`、`keyframes`、`gifDuration`、`crop`、`elapsed`，`--then` 时含 `commandExit`），供程序化取用，`frames` / `gifDuration` 读取编码后成品，`keyframes` 是参与编码的关键帧数（GIF 会额外写入尾帧）；`--json` / `-q` 下子命令输出转到 stderr，stdout 只保留结果。时长宁长勿短：静止画面会被关键帧抽取与 `--max-gap` 压掉，多录不亏。

## 转码管线

1. **录屏**：`screencapture -v` 产出 4K VFR 的 .mov。定时用 `-V`，手动停止发 SIGINT（screencapture 只在收到 SIGINT 时才写完 moov atom）。`-I` 走 `screencapture -J video`，即系统自带的录制工具条，因此能在菜单栏点按钮停止。
2. **关键帧**：`mpdecimate` 提取画面变化，再按 `1/--fps` 抽样并保留首尾状态；`--max-frames` 也保留首尾，上限为 1 时保留最终状态。自动裁剪使用抽样前的完整变化序列，避免漏掉短暂操作。屏幕录制的整帧 `scene` 分数天然极低（一行文字只改 ~1% 像素），所以不用它做主判据。
3. **自动裁剪**：把关键帧解码成 PNG 后做相邻帧差分 + 噪声门限 + `cropdetect`，得到所有运动的包围盒，换算回源分辨率并留白。
   注意：差分**不能**直接在 .mov 上做——`tblend` 对 screencapture 的流会给出恒定的假偏移；解码成 PNG 后差分才准确。
4. **编码**：关键帧 PNG 按各自时间间隔写成 concat 清单，`palettegen` + `paletteuse` 两遍编码（比单遍小一个数量级），`-loop 0` 无限循环。

## 参数

见 `s2g --help`。要点：

- `--sensitivity low|default|high`：`mpdecimate` 档位。4K 录屏每帧都带压缩噪声，ffmpeg 面向电影的默认值在这里反而是最不敏感的一档。
- `--crop auto|off|x,y,w,h`：`auto` 检测运动包围盒；运动覆盖全画面时自动退化为不裁剪。
- `--region screen|window|x,y,w,h`：录制范围，单位是屏幕点（录屏输出为 2 倍像素）。
- `--max-gap`：单帧最长停留，把长静默截断，避免 GIF 看起来卡死。
- `--then '<命令>'` / `--ready-file <路径>` / `--json`：自动化编排三件套，见上节。
- `--keep-frames` / `--keep-mov`：保留中间产物供检查。

## 故障排查

| 现象 | 原因与处理 |
|---|---|
| 录屏文件只有几 KB | 缺屏幕录制权限，按报错里的路径授权 |
| 录制进程不结束、无输出 | 录屏会话卡死（通常因上次录制被 `kill -9`）。`killall ControlCenter` 或注销恢复 |
| `--region window` 报错 | 前台应用不向 System Events 暴露窗口，改用 `--region x,y,w,h` |
| 关键帧只有几帧 | 画面确实没怎么动；或 `--sensitivity` 太低 |
| GIF 体积大 | 降 `--width` / `--fps` / `--max-frames`；确认没加 `--no-palette` |
