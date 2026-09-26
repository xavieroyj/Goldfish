# Agent notes

## macOS app icon sizing

- The supplied macOS icon assets live in `AppIcons/AppIcon.appiconset/`; `Scripts/build-app.sh` and `Scripts/prepare-app-icon.swift` generate the app's `.icns`.
- Match the *whole visible tile* to installed macOS icons, not only the artwork inside it. Stock icons use a 1024×1024 representation with a centered rounded tile around 840×840 and transparent space outside it. A rounded square touching the full canvas makes the icon look oversized in the Dock.
- The supplied 1024px artwork has an opaque white background and fills much of its canvas. Keep the tile centered at 840×840, scale the artwork to 86% of that tile, and clip it to the rounded tile. Preserve transparency outside the tile. These values are intentional optical sizing, not arbitrary decorative padding.
- When changing this pipeline, inspect the extracted 1024px representation from the generated `.icns` and compare it with installed app icons (for example OpenChamber or Safari). Do not assume macOS will add a margin or mask to a hand-built `.icns`.
- After packaging icon changes, relaunch the app for the Dock to load the new icon.
