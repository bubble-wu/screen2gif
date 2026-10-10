#!/bin/sh
# Build an isolated interactive harness for the actual settings view.
# Usage: sh native/preview-settings.sh [--off | --long] [--height 560]
set -eu
cd "$(dirname "$0")"
APP="build/SettingsPreview.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)
set -- "$@"
# Keep runtime arguments while constructing the compiler argument list.
compile_preview() {
  set -- -target "$(uname -m)-apple-macosx$MIN_OS" -parse-as-library -warnings-as-errors \
    Sources/SettingsWindow.swift Sources/SettingsStyle.swift Sources/AppPreferences.swift \
    Sources/HotKeys.swift Sources/LaunchAtLogin.swift Sources/OutputDirectory.swift \
    Sources/TextWatermark.swift Tests/SettingsPreview.swift -o "$APP/Contents/MacOS/SettingsPreview"
  SDK_FIX="$HOME/Developer/.swift-sdk-fix"
  if [ -d "$SDK_FIX/MacOSX.sdk" ] && [ -f "$SDK_FIX/vfs.yaml" ]; then
    swiftc -sdk "$SDK_FIX/MacOSX.sdk" -vfsoverlay "$SDK_FIX/vfs.yaml" "$@"
  else
    swiftc "$@"
  fi
}
compile_preview
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.wububble.screen2gif.settings-preview' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable SettingsPreview' "$APP/Contents/Info.plist"
cp -R Resources/Fonts Resources/Lucide "$APP/Contents/Resources/"
if [ "${1:-}" = "--build-only" ]; then exit 0; fi
open -n "$APP" --args "$@"
