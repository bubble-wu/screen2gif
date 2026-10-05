#!/bin/sh
# 构建 screen2gif 菜单栏 app。
#
# 用打补丁的 SDK 和 VFS overlay，是因为这台机器的 CommandLineTools 自身不一致：
# 编译器是 swiftlang-6.2.3.3.21，而 SDK 26.2 的 .swiftinterface 由 6.2.3.3.2 生成，
# Swift 会拒绝（"this SDK is not supported by the compiler"）；同时
# usr/include/swift/module.modulemap 是 2023 年的遗留副本，与 bridging.modulemap
# 重复定义 SwiftBridging。~/Developer/.swift-sdk-fix/ 里是 APFS clone 出来的 SDK
# 副本（改写了版本戳，几乎不占空间）加一个把旧 modulemap 换成空文件的 overlay。
# CLT 干净重装后这两个参数都可以去掉。
#
# SwiftPM 在这台机器上另有故障（libPackageDescription 与其 swiftmodule 不匹配），
# 所以直接用 swiftc 编译再手工组装 .app。
set -eu
cd "$(dirname "$0")"

SDK="/Users/wububble/Developer/.swift-sdk-fix/MacOSX.sdk"
VFS="/Users/wububble/Developer/.swift-sdk-fix/vfs.yaml"
TARGET="arm64-apple-macosx26.2"
APP="build/screen2gif.app"

# 版本一致性校验：CLI（bin/screen2gif 的 VERSION）是唯一真源，Info.plist 靠手工同步，
# v1.2/v1.3 就是这样掉队的——构建时挡住，别再靠 review 兜底。
CLI_VER=$(sed -n "s/^const VERSION = '\(.*\)';/\1/p" ../bin/screen2gif)
PLIST_VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist 2>/dev/null)
[ "$CLI_VER" = "$PLIST_VER" ] || {
  echo "error: 版本不一致 CLI=${CLI_VER} GUI=${PLIST_VER}，请同步 native/Info.plist 的 CFBundleShortVersionString" >&2
  exit 1
}

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -sdk "$SDK" -vfsoverlay "$VFS" -target "$TARGET" \
  -parse-as-library -O -whole-module-optimization \
  Sources/*.swift -o "$APP/Contents/MacOS/screen2gif"

cp Info.plist "$APP/Contents/Info.plist"

# 必须用固定身份签名而不是 ad-hoc：ad-hoc 的 designated requirement 就是 cdhash，
# 每次重建都变，TCC 的屏幕录制授权随之失效，用户得反复去系统设置里重加。
# 证书 "screen2gif Dev" 是自签名根（login keychain 里受信任），DR 只认证书哈希。
IDENTITY="screen2gif Dev"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  echo "warning: 找不到签名身份 \"$IDENTITY\"，退回 ad-hoc；重建后屏幕录制授权会失效" >&2
  IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" "$APP"

echo "✓ $APP"
