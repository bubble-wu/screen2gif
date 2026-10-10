#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p build/tests
cp -R Resources/Fonts Resources/Lucide build/tests/
SDK_FIX="$HOME/Developer/.swift-sdk-fix"
MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)
TARGET="$(uname -m)-apple-macosx$MIN_OS"
set -- -target "$TARGET" -parse-as-library -warnings-as-errors \
  Sources/RecordingLifecycle.swift Sources/CaptureIcon.swift Sources/RegionPicker.swift \
  Sources/AppPreferences.swift Sources/TextWatermark.swift Sources/LaunchAtLogin.swift \
  Sources/HotKeys.swift \
  Sources/SettingsStyle.swift Sources/SettingsWindow.swift Sources/OutputDirectory.swift \
  Tests/RegressionTests.swift -o build/tests/regressions
if [ -d "$SDK_FIX/MacOSX.sdk" ] && [ -f "$SDK_FIX/vfs.yaml" ]; then
  swiftc -sdk "$SDK_FIX/MacOSX.sdk" -vfsoverlay "$SDK_FIX/vfs.yaml" "$@"
else
  swiftc "$@"
fi
build/tests/regressions
