#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
swift build -c release
APP="$ROOT/build/Goldfish.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/Goldfish" "$APP/Contents/MacOS/Goldfish"
cp "$ROOT/Packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Sources/Goldfish/Resources/GoldfishWhite.png" "$APP/Contents/Resources/GoldfishWhite.png"
cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
printf 'Built %s\n' "$APP"
