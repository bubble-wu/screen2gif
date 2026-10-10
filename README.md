<img src="native/Resources/AppIcon.png" width="72" alt="screen2gif 应用图标">

# screen2gif

把 macOS 屏幕操作变成便于分享的 GIF：保留画面变化，裁掉静止区域，压缩等待时间。

**[下载 macOS App · DMG · v1.5.0](https://github.com/bubble-wu/screen2gif/releases/download/v1.5.0/screen2gif-v1.5.0-macOS-arm64.dmg)** · [所有版本](https://github.com/bubble-wu/screen2gif/releases) · [下载 CLI 源码](https://github.com/bubble-wu/screen2gif/archive/refs/heads/main.zip)

App：macOS 15+ · Apple Silicon（M1 及更新芯片）· 约 13 MB。Intel Mac 可[从源码构建](docs/development.md)。App 与 CLI 均需 Node.js ≥ 18 和 ffmpeg。

## 能做什么

- **点着录**：菜单栏全屏录制或框选区域，快捷键开始与停止，录完自动导出。
- **精简动图**：提取变化帧、缩短静止等待、自动裁剪，减少 GIF 体积。
- **按需导出**：三档画质、输出文件夹、文字与 emoji 水印，设置自动保存。
- **交给脚本**：CLI 支持已有视频转 GIF，以及边执行命令边录制。

## 开始使用

1. 下载并打开 DMG，把 `screen2gif.app` 拖到窗口里的 `Applications`，复制完成后推出磁盘，再从「应用程序」打开 App。
2. 缺依赖时，点击菜单里的「安装缺失依赖…」（需要 [Homebrew](https://brew.sh)），或自行执行 `brew install node ffmpeg`。
3. 在「系统设置 → 隐私与安全性 → 屏幕与系统录音」中启用 `screen2gif`；没有时点 `+` 添加 App，然后退出并重新打开。
4. 选「框选区域录制…」，拖拽选区；演示结束后点击状态条上的「停止」。GIF 默认保存到桌面，并在访达中显示。

| 动作 | 默认快捷键 |
|---|---|
| 录制全屏 | ⇧⌘6 |
| 框选区域 | ⇧⌘7 |
| 停止录制 | ⇧⌘8 |

画质、存储位置、水印和快捷键都在「设置…」里。App 当前录制主屏；全屏自动裁剪，框选保留所选范围。

<details>
<summary>查看设置界面</summary>

<img src="screenshots/settings-optimized.png" width="480" alt="screen2gif 设置：输出位置、画质、快捷键、开机自启动与文本水印。原生视图离屏渲染，示例偏好。">

</details>

## 首次打开的安全提示

当前版本尚未使用 Apple Developer ID 签名和公证。若提示 **「Apple 无法验证 screen2gif 是否包含可能危害 Mac 安全或泄漏隐私的恶意软件」**：

1. 确认下载来自本仓库的 [Releases](https://github.com/bubble-wu/screen2gif/releases)，选择「完成」或「取消」。
2. 打开「系统设置 → 隐私与安全性」，找到 `screen2gif` 的提示，点击「仍要打开」，再确认「打开」。

操作依据 [Apple 官方说明](https://support.apple.com/zh-cn/102445)。如果提示的是「会损坏你的电脑／包含恶意软件」，请停止打开；「App 已损坏」请先重新下载并校验，详见[安全提示排查](docs/macos-app.md#安全提示排查)。

## CLI 快速上手

已安装 Node.js 与 ffmpeg 后，[下载源码](https://github.com/bubble-wu/screen2gif/archive/refs/heads/main.zip) 解压，或 clone 仓库；无需 `npm install`。

```sh
git clone https://github.com/bubble-wu/screen2gif.git
cd screen2gif
./bin/screen2gif doctor
./bin/screen2gif record -d 8 -o demo.gif   # 录制 8 秒
./bin/screen2gif convert input.mov -o demo.gif
```

CLI 的屏幕录制权限授予运行命令的终端。全部参数见 `./bin/screen2gif --help`；Agent 注册和自动化示例见 [CLI 文档](docs/cli.md)。

## 更多说明

[App 使用与故障排查](docs/macos-app.md) · [CLI 参数与自动化](docs/cli.md) · [开发与构建](docs/development.md) · [Agent skill](SKILL.md) · [MIT License](LICENSE)
