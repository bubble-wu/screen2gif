#!/bin/sh
# Create the drag-to-Applications installer using macOS tools only.
set -eu
cd "$(dirname "$0")"

APP=${1:-build/screen2gif.app}
if [ ! -d "$APP" ]; then
  echo "error: 找不到 $APP；请先运行 ./native/build.sh" >&2
  exit 1
fi
APP=$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")
codesign --verify --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
CLI_VERSION=$("$APP/Contents/Resources/cli/bin/screen2gif" --version)
[ "$VERSION" = "$CLI_VERSION" ] || { echo "error: App 与内置 CLI 版本不一致" >&2; exit 1; }
ARCH=$(lipo -archs "$APP/Contents/MacOS/screen2gif")
case "$ARCH" in
  arm64|x86_64) ;;
  "x86_64 arm64"|"arm64 x86_64") ARCH=universal ;;
  *) echo "error: 不支持的架构 $ARCH" >&2; exit 1 ;;
esac
OUTPUT="$(pwd)/build/screen2gif-v${VERSION}-macOS-${ARCH}.dmg"
if [ -e "$OUTPUT" ]; then
  echo "error: $OUTPUT 已存在，请先移动它再重新打包" >&2
  exit 1
fi

# Keep working files in the ignored build directory. Never replace an existing
# package, modify the source App, or copy anything into /Applications.
WORK=$(mktemp -d "$(pwd)/build/dmg-work.XXXXXX")
MOUNT="$WORK/volume"
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background" "$MOUNT"
ditto "$APP" "$STAGE/screen2gif.app"
ln -s /Applications "$STAGE/Applications"

SDK_FIX="$HOME/Developer/.swift-sdk-fix"
set -- -target "$(uname -m)-apple-macosx15.0" -parse-as-library \
  tools/dmg-background.swift -o "$WORK/dmg-background"
if [ -d "$SDK_FIX/MacOSX.sdk" ] && [ -f "$SDK_FIX/vfs.yaml" ]; then
  swiftc -sdk "$SDK_FIX/MacOSX.sdk" -vfsoverlay "$SDK_FIX/vfs.yaml" "$@"
else
  swiftc "$@"
fi
"$WORK/dmg-background" "$STAGE/.background/installer.png" "$VERSION"

hdiutil create -quiet -srcfolder "$STAGE" -volname "screen2gif" \
  -fs HFS+ -format UDRW "$WORK/installer-rw.dmg"
hdiutil attach -quiet -nobrowse -mountpoint "$MOUNT" "$WORK/installer-rw.dmg"
MOUNTED=1
cleanup() {
  if [ "$MOUNTED" = 1 ]; then
    hdiutil detach -quiet "$MOUNT" || echo "warning: 请手动推出 $MOUNT" >&2
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

python3 tools/dmg-layout.py "$MOUNT"
[ -f "$MOUNT/.DS_Store" ] || { echo "error: 未生成安装窗口布局" >&2; exit 1; }
codesign --verify --strict "$MOUNT/screen2gif.app"
[ "$(readlink "$MOUNT/Applications")" = /Applications ] || {
  echo "error: 安装目标快捷入口不正确" >&2
  exit 1
}
sync
hdiutil detach -quiet "$MOUNT"
MOUNTED=0
hdiutil convert -quiet "$WORK/installer-rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUTPUT"
hdiutil verify -quiet "$OUTPUT"
(cd build && shasum -a 256 "$(basename "$OUTPUT")") > "$OUTPUT.sha256"
echo "✓ $OUTPUT"
echo "✓ $OUTPUT.sha256"
