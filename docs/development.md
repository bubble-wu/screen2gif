# 开发与构建

[返回首页](../README.md) · [CLI 使用说明](cli.md) · [macOS App 使用说明](macos-app.md)

## 从源码构建

原生 App 要求 macOS 15+，使用 Swift / Xcode Command Line Tools。CLI 与测试需要 Node.js ≥ 18、ffmpeg / ffprobe；没有 npm 依赖，无需 `npm install`。

```sh
git clone https://github.com/bubble-wu/screen2gif.git
cd screen2gif
brew install node ffmpeg
./native/build.sh
open native/build/screen2gif.app
```

构建默认使用当前机器架构，因此 Intel Mac 可在本机编译。`S2G_ARCH` 可覆盖目标架构；构建脚本从 `native/Info.plist` 读取最低系统版本，并校验它与 CLI 的版本一致。

构建产物为 `native/build/screen2gif.app`，内置 `bin/`、`lib/` 与 `package.json`，可移动到其他目录；Node.js 与 ffmpeg 仍为外部依赖。

## 打包 DMG

```sh
./native/package-dmg.sh
```

脚本使用 macOS 自带的 `hdiutil`、Swift / AppKit 和 Python 3 标准库，不需要安装 `create-dmg` 或额外 Python 包，也不需要控制 Finder。先运行 `build.sh`，再打包；可传入已有 App 路径作为第一个参数。

DMG 包含 App、指向 `/Applications` 的快捷入口，以及中文拖拽引导背景。Finder 窗口布局由 `.DS_Store` 写入器生成，背景别名使用系统 Alias Manager API；不会向本机 `/Applications` 写入文件。脚本校验 App 与内置 CLI 版本、签名、镜像完整性及快捷入口。

产物命名为 `native/build/screen2gif-v<版本>-macOS-<架构>.dmg`，旁边生成 `.sha256` 文件。脚本拒绝覆盖已有 DMG；如需重新打包，先把旧产物移到其他位置。中间产物保留在已忽略的 `native/build/dmg-work.*` 中，便于检查。

发布时将 DMG 与 `SHA256SUMS.txt` 上传到对应 Release；校验文件应列出本版每个下载包的 SHA-256 和文件名。v1.5.0 的备用 ZIP 保留，生成方式如下：

```sh
# 从仓库根目录执行；版本号以 ./bin/screen2gif --version 为准
S2G_VERSION=$(./bin/screen2gif --version)
ditto -c -k --sequesterRsrc --keepParent native/build/screen2gif.app \
  "native/build/screen2gif-v${S2G_VERSION}-macOS.zip"
```

发布前确认实际二进制架构（`file native/build/screen2gif.app/Contents/MacOS/screen2gif`），并在下载说明中注明。当前 v1.5.0 发布包为 arm64。

## 签名与权限

`build.sh` 优先使用钥匙串中的自签名身份 `screen2gif Dev`。固定身份使屏幕录制授权在重建后保持稳定；找不到该身份时会退回 ad-hoc 签名并告警，此时重建后需重新授权。

自签名不等于 Apple Developer ID 签名。下载到其他 Mac 后首次打开可能受系统限制，操作见[首次打开说明](macos-app.md#下载与首次打开)。

DMG 打包不会绕过 Gatekeeper。若要让首次打开不再出现未公证提示，需要使用 Apple Developer Program 的 Developer ID Application 证书签名，开启 hardened runtime，按 [Apple 公证流程](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) 提交并把公证票据附加到分发产物。当前仓库发布包尚未完成此流程，`codesign --verify` 通过不能当作 Gatekeeper 或公证通过。

本机启动测试应通过 `open native/build/screen2gif.app`。直接运行 bundle 中的二进制可能继承终端的屏幕录制权限，不能证明 App 自身已获授权。

构建与测试脚本在存在 `~/Developer/.swift-sdk-fix/MacOSX.sdk` 和 `vfs.yaml` 时使用本机 SDK 补丁；普通环境使用系统 SDK。补丁不是仓库依赖，也无需在正常机器上创建。

## 验证

```sh
npm test
npm run test:native
./native/build.sh
codesign --verify --strict native/build/screen2gif.app
./native/package-dmg.sh
```

- CLI 测试覆盖合成视频、裁剪、限帧、JSON 与 ready-file，不录制真实屏幕。
- 原生回归测试覆盖会话、超时与取消、窗口、图标、设置持久化和导出参数。
- GitHub Actions 在 macOS 15 执行上述检查，包括 DMG 打包。

屏幕录制授权、真实录制与导出、多显示器行为、不同系统版本的 UI 需要对应机器验收；自动化测试通过不代表这些项目已通过。

## 目录

| 路径 | 内容 |
|---|---|
| `bin/screen2gif` | CLI 入口与参数解析 |
| `lib/record.mjs` | 录制、停止、窗口区域与就绪信号 |
| `lib/video.mjs` | 探测、关键帧抽取、裁剪与 GIF 编码 |
| `native/` | SwiftUI 菜单栏 App 与 ScreenCaptureKit 采集 |
| `native/Resources/` | App 图标、字体与 Lucide 图标 |
| `native/package-dmg.sh`、`native/tools/dmg-*` | DMG 打包、引导背景与 Finder 布局 |
| `design/settings.pen` | 设置界面设计源，主要节点 `jNug5 / AAfT7` |
| `screenshots/` | 演示截图与原生视图离屏预览 |
| `test/`、`native/Tests/` | CLI 与原生回归测试 |
| `docs/reviews/` | 历次审查与修复记录 |
| `SKILL.md` | Agent skill 使用说明 |

字体与图标的许可证、资源来源和校验值见 [native/Resources/README.md](../native/Resources/README.md)。仓库使用 [MIT License](../LICENSE)。
