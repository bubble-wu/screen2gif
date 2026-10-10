#!/bin/sh
# 构建 screen2gif 菜单栏 app。
#
# 维护者这台机器的 CommandLineTools 自身不一致：编译器是 swiftlang-6.2.3.3.21，
# 而 SDK 26.2 的 .swiftinterface 由 6.2.3.3.2 生成，Swift 会拒绝（"this SDK is not
# supported by the compiler"）；同时 usr/include/swift/module.modulemap 是 2023 年的
# 遗留副本，与 bridging.modulemap 重复定义 SwiftBridging。~/Developer/.swift-sdk-fix/
# 里是 APFS clone 出来的 SDK 副本（改写了版本戳，几乎不占空间）加一个把旧 modulemap
# 换成空文件的 overlay。下面检测到副本存在才启用；普通环境直接用系统默认 SDK。
#
# SwiftPM 在这台机器上另有故障（libPackageDescription 与其 swiftmodule 不匹配），
# 所以直接用 swiftc 编译再手工组装 .app。
set -eu
cd "$(dirname "$0")"

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

MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)
ARCH=${S2G_ARCH:-$(uname -m)}
TARGET="$ARCH-apple-macosx$MIN_OS"
SDK_FIX="$HOME/Developer/.swift-sdk-fix"
if [ -d "$SDK_FIX/MacOSX.sdk" ] && [ -f "$SDK_FIX/vfs.yaml" ]; then
  swiftc -sdk "$SDK_FIX/MacOSX.sdk" -vfsoverlay "$SDK_FIX/vfs.yaml" \
    -target "$TARGET" -parse-as-library -O -whole-module-optimization \
    Sources/*.swift -o "$APP/Contents/MacOS/screen2gif"
else
  swiftc -target "$TARGET" -parse-as-library -O -whole-module-optimization \
    Sources/*.swift -o "$APP/Contents/MacOS/screen2gif"
fi

cp Info.plist "$APP/Contents/Info.plist"
cp -R Resources/Fonts Resources/Lucide "$APP/Contents/Resources/"
# Embed the complete ESM CLI, so moving the .app cannot break conversion.
CLI="$APP/Contents/Resources/cli"
mkdir -p "$CLI/bin" "$CLI/lib"
cp ../bin/screen2gif "$CLI/bin/"
cp ../lib/*.mjs "$CLI/lib/"
cp ../package.json "$CLI/"
chmod +x "$CLI/bin/screen2gif"

ICONSET="build/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# 必须用固定身份签名而不是 ad-hoc：ad-hoc 的 designated requirement 就是 cdhash，
# 每次重建都变，TCC 的屏幕录制授权随之失效，用户得反复去系统设置里重加。
# 证书 "screen2gif Dev" 是自签名根（login keychain 里受信任），DR 只认证书哈希。
IDENTITY="screen2gif Dev"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  echo "warning: 找不到签名身份 \"$IDENTITY\"，退回 ad-hoc；重建后屏幕录制授权会失效" >&2
  IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" "$APP"

# Replacing files inside an existing bundle does not update its directory mtime.
# Finder/Launch Services can otherwise keep the pre-icon application metadata.
touch "$APP"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$APP" || echo "warning: 无法刷新 app 的系统登记，请重新打开 Finder 中的应用目录" >&2
fi

echo "✓ $APP"
