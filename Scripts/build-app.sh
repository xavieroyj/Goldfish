#!/bin/zsh
set -euo pipefail

# Optional environment:
#   UNIVERSAL=1      build a universal (arm64 + x86_64) binary instead of the host architecture
#   VERSION=1.2.3    stamp CFBundleShortVersionString / CFBundleVersion in the bundled Info.plist

ROOT="${0:A:h:h}"
cd "$ROOT"
APP="$ROOT/build/Goldfish.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
  # Build each architecture separately and merge; a multi-arch `swift build` needs full Xcode.
  SLICES=()
  for ARCH in arm64 x86_64; do
    swift build -c release --arch "$ARCH"
    SLICES+=("$(swift build -c release --arch "$ARCH" --show-bin-path)/Goldfish")
  done
  lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/Goldfish"
else
  swift build -c release
  cp ".build/release/Goldfish" "$APP/Contents/MacOS/Goldfish"
fi
cp "$ROOT/Packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Sources/Goldfish/Resources/GoldfishWhite.png" "$APP/Contents/Resources/GoldfishWhite.png"
cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
if [[ -n "${VERSION:-}" ]]; then
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
fi
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
printf 'Built %s\n' "$APP"
