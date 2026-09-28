#!/bin/bash
# Builds a universal Lockbox.app into build/.
#   ./build.sh install   also installs it to ~/Applications and registers it with Finder
#   ./build.sh release   also zips it as build/Lockbox.zip for a GitHub release
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Lockbox.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/tmp

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos14" Sources/*.swift -o "build/tmp/Lockbox-$arch"
done
lipo -create build/tmp/Lockbox-arm64 build/tmp/Lockbox-x86_64 -output "$APP/Contents/MacOS/Lockbox"
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

if [[ "${1:-}" == "release" ]]; then
  ditto -c -k --keepParent "$APP" build/Lockbox.zip
  echo "Packaged build/Lockbox.zip"
fi
