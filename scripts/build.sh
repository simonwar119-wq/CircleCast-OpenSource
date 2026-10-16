#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p .build/module-cache dist
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build -c release --disable-sandbox --cache-path "$PWD/.build/cache" -debug-info-format none
APP="$PWD/dist/头像录屏.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/CircleCast "$APP/Contents/MacOS/CircleCast"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ ! -f Resources/AppIcon.icns ]]; then
    swift scripts/make-icon.swift Resources/AppIcon.iconset
    iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier local.circlecast.recorder "$APP"
codesign --verify --strict --verbose=2 "$APP"
print "Built: $APP"
du -sh "$APP"
