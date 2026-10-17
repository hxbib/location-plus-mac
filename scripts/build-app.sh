#!/bin/bash
# Builds build/Location+.app (universal) and, with --dmg, build/Location+.dmg.
# Pass --install to copy the app into /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/LocationPlus"

APP="build/Location+.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LocationPlus"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp engine/engine.py engine/requirements.txt "$APP/Contents/Resources/"

VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)}"
BUILD="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $BUILD" "$APP/Contents/Info.plist"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"
lipo -info "$APP/Contents/MacOS/LocationPlus"
echo "Built $APP ($VERSION build $BUILD)"

if [[ " $* " == *" --dmg "* ]]; then
  STAGE="$(mktemp -d)/Location+"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  DMG="build/Location+.dmg"
  rm -f "$DMG"
  hdiutil create -volname "Location+" -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DMG" >/dev/null
  hdiutil verify "$DMG" >/dev/null
  echo "Built $DMG"
fi

if [[ " $* " == *" --install "* ]]; then
  rm -rf "/Applications/Location+.app"
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Location+.app"
fi
