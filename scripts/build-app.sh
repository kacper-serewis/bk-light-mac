#!/bin/sh
# Builds a release BK Light.app into ./build (ad-hoc signed).
# Pass --install to copy it to /Applications (do this before enabling "Start at login",
# since the login item points at wherever the app was when it was enabled).
set -eu
cd "$(dirname "$0")/.."
swift build -c release
APP="build/BK Light.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/BKLight" "$APP/Contents/MacOS/BKLight"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
if [ "${1:-}" = "--install" ]; then
    pkill -x BKLight || true
    rm -rf "/Applications/BK Light.app"
    cp -R "$APP" /Applications/
    echo "Installed /Applications/BK Light.app"
fi
