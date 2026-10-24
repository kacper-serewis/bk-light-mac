#!/bin/sh
# Builds a release BK Light.app into ./build, signed with the first "Apple Development"
# identity in the keychain (override with SIGN_IDENTITY=..., or SIGN_IDENTITY=- for ad-hoc).
# A real identity keeps the code requirement stable across builds, so macOS keeps the
# Screen Recording / Bluetooth / Automation permissions; ad-hoc builds lose them on every rebuild.
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
# Matched by SHA-1 rather than name, which can contain non-ASCII characters.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/"Apple Development: / { print $2; exit }')}"
IDENTITY="${IDENTITY:--}"
codesign --force --sign "$IDENTITY" "$APP"
echo "Built $APP (signed with: $IDENTITY)"
if [ "${1:-}" = "--install" ]; then
    pkill -x BKLight || true
    rm -rf "/Applications/BK Light.app"
    cp -R "$APP" /Applications/
    echo "Installed /Applications/BK Light.app"
fi
