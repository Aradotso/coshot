#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

echo "▶ building release binary…"
swift build -c release

BIN=".build/release/coshot"
APP="coshot.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/coshot"
cp Info.plist "$APP/Contents/Info.plist"

# Copy the SPM resource bundle into Resources/ so Bundle.module resolves.
RBUNDLE=$(find .build -name "coshot_coshot.bundle" -type d -path "*release*" -print -quit || true)
if [ -n "${RBUNDLE:-}" ]; then
  rm -rf "$APP/Contents/Resources/coshot_coshot.bundle"
  cp -R "$RBUNDLE" "$APP/Contents/Resources/"
else
  echo "⚠ warning: resource bundle not found — prompts.default.json will not load"
fi

# Copy the .icns to the top-level Contents/Resources so CFBundleIconFile resolves.
# (It's also inside the SPM bundle but Finder / Dock only look at the top level.)
if [ -f Sources/coshot/Resources/AppIcon.icns ]; then
  cp Sources/coshot/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc sign so the system can track permissions across rebuilds.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "✓ built $APP"
echo ""
echo "Next:"
echo "  1. mv $APP /Applications/"
echo "  2. open /Applications/$APP"
echo "  3. grant Screen Recording + Accessibility in System Settings → Privacy & Security"
echo "  4. click the ⚡ menu bar icon → Set Cerebras API Key"
echo "  5. press ⌥Space to summon"
