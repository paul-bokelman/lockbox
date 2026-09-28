#!/bin/bash
# Builds Lockbox.app into build/. `./build.sh install` also installs it to ~/Applications
# and registers it with Finder (the .lockbox file type and the "Encrypt with Lockbox" menu item).
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Lockbox.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/tmp

swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14" Sources/*.swift -o "$APP/Contents/MacOS/Lockbox"
cp Info.plist "$APP/Contents/"

swiftc -O tools/make-icon.swift -o build/tmp/make-icon
build/tmp/make-icon build/tmp/LockedFolder.iconset
build/tmp/make-icon build/tmp/UnlockedFolder.iconset --open
iconutil -c icns build/tmp/LockedFolder.iconset -o "$APP/Contents/Resources/LockedFolder.icns"
iconutil -c icns build/tmp/UnlockedFolder.iconset -o "$APP/Contents/Resources/UnlockedFolder.icns"
rm -rf build/tmp

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
  LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  pkill -x Lockbox || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/Lockbox.app
  cp -R "$APP" ~/Applications/
  "$LSREGISTER" -u "$PWD/$APP" 2>/dev/null || true
  "$LSREGISTER" -f ~/Applications/Lockbox.app
  /System/Library/CoreServices/pbs -update
  echo "Installed ~/Applications/Lockbox.app"
fi
