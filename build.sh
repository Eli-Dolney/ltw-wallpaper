#!/bin/zsh
# Builds build/LtwWallpaper.app with the Command Line Tools (no Xcode project needed).
set -e
cd "$(dirname "$0")"
APP=build/LtwWallpaper.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 \
  -framework Cocoa -framework WebKit \
  Sources/*.swift -o "$APP/Contents/MacOS/LtwWallpaper"
cp Info.plist "$APP/Contents/Info.plist"
cp -R scenes "$APP/Contents/Resources/scenes"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Sign with the local "Ltw Wallpaper Dev" identity when it exists (tools/make-signing-cert.sh creates it), so
# privacy permissions survive rebuilds; otherwise ad-hoc, which macOS treats as a new app every build.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Ltw Wallpaper Dev"; then
  codesign --force --sign "Ltw Wallpaper Dev" "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP" >/dev/null 2>&1 || true
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi
# The app reads scenes from Application Support (reading them from a Desktop folder would trigger a
# macOS privacy prompt on every rebuild). Mirror this project's scenes/ there.
defaults delete com.ltw.wallpaper scenesPath >/dev/null 2>&1 || true
SCENES="$HOME/Library/Application Support/LtwWallpaper/scenes"
mkdir -p "$SCENES"
rsync -a scenes/ "$SCENES/"
echo "Built $APP"
