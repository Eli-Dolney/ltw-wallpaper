#!/bin/zsh
# Rebuild, install to /Applications, restart the wallpaper app.
# Only the /Applications copy is ever launched, so there is a single menu bar icon; the copy in
# build/ is just the compiler output. Set LTW_INSTALL=0 to run the build/ copy instead.
set -e
cd "$(dirname "$0")"
./build.sh
pkill -x LtwWallpaper 2>/dev/null || true
sleep 0.3
if [ "${LTW_INSTALL:-1}" != 0 ] && [ -w /Applications ]; then
  rm -rf /Applications/LtwWallpaper.app
  cp -R build/LtwWallpaper.app /Applications/LtwWallpaper.app
  # Make sure "open -a LtwWallpaper" and ltw:// links resolve to the installed copy, not build/.
  LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  "$LSR" -u "$PWD/build/LtwWallpaper.app" >/dev/null 2>&1 || true
  "$LSR" -f /Applications/LtwWallpaper.app >/dev/null 2>&1 || true
  open /Applications/LtwWallpaper.app
  echo "Installed and running /Applications/LtwWallpaper.app. Look for the sparkles icon in the menu bar."
else
  open build/LtwWallpaper.app
  echo "Running build/LtwWallpaper.app. Look for the sparkles icon in the menu bar."
fi
