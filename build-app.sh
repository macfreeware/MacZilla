#!/bin/bash
# Builds MacZilla.app into ./build.
#   --install  copy it to /Applications
#   --zip      also make build/release/MacZilla-<version>.zip and its SHA-256
set -euo pipefail
cd "$(dirname "$0")"

# Universal binary: Apple Silicon and Intel
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release --product MacZilla "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"
APP="build/MacZilla.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MacZilla" "$APP/Contents/MacOS/MacZilla"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp LICENSE "$APP/Contents/Resources/LICENSE"
# Translations (tr is the source language, en is translated)
cp -R Resources/*.lproj "$APP/Contents/Resources/"

# App icon: Resources/IconArtwork.png, cut out and placed by Scripts/make-icon.swift
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
swift Scripts/make-icon.swift Resources/IconArtwork.png build/icon_1024.png
sips -z 256 256 build/icon_1024.png --out Resources/AppIcon.png >/dev/null
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$APP/Contents/Resources/AppIcon.icns" Resources/AppIcon.icns

# Build number and commit from git, when available
PB=/usr/libexec/PlistBuddy
if git rev-parse --git-dir >/dev/null 2>&1 && git rev-parse HEAD >/dev/null 2>&1; then
  "$PB" -c "Set :CFBundleVersion $(git rev-list --count HEAD)" "$APP/Contents/Info.plist"
  "$PB" -c "Add :MacZillaCommit string $(git rev-parse --short HEAD)" "$APP/Contents/Info.plist"
fi

codesign --force --sign - "$APP" >/dev/null

if [[ "${1:-}" == "--zip" ]]; then
    VERSION="$("$PB" -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
    mkdir -p build/release
    ZIP="build/release/MacZilla-$VERSION.zip"
    rm -f "$ZIP" "$ZIP.sha256"
    # The zip holds a folder with the app and the GPL license text.
    STAGE="build/release/MacZilla-$VERSION"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    cp LICENSE "$STAGE/LICENSE.txt"
    ditto -c -k --norsrc --keepParent "$STAGE" "$ZIP"
    rm -rf "$STAGE"
    (cd build/release && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
    echo "Paket: $ZIP"
elif [[ "${1:-}" == "--install" ]]; then
    rm -rf /Applications/MacZilla.app
    cp -R "$APP" /Applications/
    echo "Kuruldu: /Applications/MacZilla.app"
else
    echo "Hazır: $APP"
fi
