#!/usr/bin/env bash
# Ship a signed + notarized coshot release to GitHub.
#
# Pulls Apple signing secrets from Railway (Ara Backend / prd / mac-setup),
# builds release binary, wraps into .app, hardens + signs with Developer ID,
# notarizes via Apple notary service, staples, zips, creates GitHub Release.
#
# Usage:
#   ./release.sh           # auto-bump patch version
#   ./release.sh 0.1.5     # explicit version
#
# Teammates install the zip from GitHub Releases once, and future runs of this
# script push new signed builds that they can drop in by running the in-app
# "Check for Updates" menu item (Sparkle) — or by re-downloading from Releases.

set -euo pipefail
cd "$(dirname "$0")"

RAILWAY_PROJECT="5b03413d-9ace-4617-beb5-18b26ce5f339"   # Ara Backend
RAILWAY_ENV="prd"
RAILWAY_SVC="mac-setup"
GH_REPO="Aradotso/coshot"

# ---------------------------------------------------------------------------
# Version bump
# ---------------------------------------------------------------------------
CURRENT=$(plutil -extract CFBundleShortVersionString raw Info.plist)
if [ $# -ge 1 ]; then
  VERSION="$1"
else
  # auto-bump patch
  IFS='.' read -r MAJ MIN PATCH <<<"$CURRENT"
  VERSION="$MAJ.$MIN.$((PATCH + 1))"
fi
echo "▶ $CURRENT → $VERSION"

# ---------------------------------------------------------------------------
# Pull signing secrets from Railway
# ---------------------------------------------------------------------------
echo "▶ fetching Apple secrets from Railway ($RAILWAY_SVC / $RAILWAY_ENV)…"
# Requires: railway link --project $RAILWAY_PROJECT --environment $RAILWAY_ENV
#                        --service $RAILWAY_SVC   (run once in this dir)
RAILWAY_KV=$(railway variables --kv 2>/dev/null | grep "^APPLE_" || true)

if [ -z "$RAILWAY_KV" ]; then
  echo "✗ no APPLE_* vars in Railway — is the CLI logged in?" >&2
  exit 1
fi

# Export in a subshell-safe way
while IFS='=' read -r key value; do
  export "$key=$value"
done <<<"$RAILWAY_KV"

: "${APPLE_CODESIGN_DEVELOPER_ID_IDENTITY:?missing}"
: "${APPLE_CODESIGN_P12_CERTIFICATE_B64:?missing}"
: "${APPLE_CODESIGN_P12_CERTIFICATE_PASSWORD:?missing}"
: "${APPLE_DEVELOPER_ACCOUNT_EMAIL:?missing}"
: "${APPLE_DEVELOPER_APP_SPECIFIC_PASSWORD:?missing}"
: "${APPLE_DEVELOPER_TEAM_ID:?missing}"

# ---------------------------------------------------------------------------
# Ensure signing identity is in login keychain (imported once, persists)
# ---------------------------------------------------------------------------
if ! security find-identity -v -p codesigning 2>/dev/null \
     | grep -q "$APPLE_CODESIGN_DEVELOPER_ID_IDENTITY"; then
  echo "▶ importing Developer ID cert into login keychain…"
  P12_FILE=$(mktemp -t coshot-cert).p12
  trap 'rm -f "$P12_FILE"' EXIT
  echo "$APPLE_CODESIGN_P12_CERTIFICATE_B64" | base64 -d > "$P12_FILE"
  security import "$P12_FILE" \
    -P "$APPLE_CODESIGN_P12_CERTIFICATE_PASSWORD" \
    -T /usr/bin/codesign
  rm -f "$P12_FILE"
else
  echo "▶ Developer ID cert already in login keychain"
fi

# ---------------------------------------------------------------------------
# Build + bundle
# ---------------------------------------------------------------------------
plutil -replace CFBundleShortVersionString -string "$VERSION" Info.plist
plutil -replace CFBundleVersion -string "$VERSION" Info.plist

echo "▶ building release binary…"
swift build -c release

echo "▶ wrapping into .app bundle…"
./build-app.sh >/dev/null

# ---------------------------------------------------------------------------
# Sanitize bundle before signing
# macOS 14+ writes com.apple.provenance xattrs on every file. ditto then
# packs those as AppleDouble ._* entries inside the zip, which extract as
# real files on the install side and invalidate the code-signature seal
# (→ "coshot is damaged" Gatekeeper warning). Strip them now.
# ---------------------------------------------------------------------------
echo "▶ sanitizing bundle (xattrs + AppleDouble)…"
/usr/bin/xattr -cr coshot.app
/usr/bin/dot_clean -fm coshot.app 2>/dev/null || true
/usr/bin/find coshot.app -name '._*' -delete 2>/dev/null || true

# ---------------------------------------------------------------------------
# Sign with Developer ID + hardened runtime
# ---------------------------------------------------------------------------
echo "▶ signing with '$APPLE_CODESIGN_DEVELOPER_ID_IDENTITY'…"
codesign --force --deep --timestamp --options runtime \
  --sign "$APPLE_CODESIGN_DEVELOPER_ID_IDENTITY" \
  coshot.app

codesign --verify --verbose=2 coshot.app
spctl --assess --verbose=2 --type execute coshot.app || true

# ---------------------------------------------------------------------------
# Notarize (optional — set SKIP_NOTARIZE=1 to bypass)
# ---------------------------------------------------------------------------
echo "▶ zipping…"
rm -f coshot.zip
/usr/bin/zip -qry coshot.zip coshot.app

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
  echo "⚠ SKIP_NOTARIZE=1 — shipping signed-only build"
  echo "  teammates will need: xattr -dr com.apple.quarantine /Applications/coshot.app"
else
  echo "▶ submitting to Apple notary service (30-90s)…"
  if xcrun notarytool submit coshot.zip \
    --apple-id "$APPLE_DEVELOPER_ACCOUNT_EMAIL" \
    --team-id "$APPLE_DEVELOPER_TEAM_ID" \
    --password "$APPLE_DEVELOPER_APP_SPECIFIC_PASSWORD" \
    --wait; then
    echo "▶ stapling notarization ticket…"
    xcrun stapler staple coshot.app
    xcrun stapler validate coshot.app
    rm coshot.zip
    /usr/bin/zip -qry coshot.zip coshot.app
  else
    echo ""
    echo "⚠ notarization failed — shipping signed-only build"
    echo "  re-run with SKIP_NOTARIZE=1 to skip this prompt next time"
    echo "  or fix: log in to developer.apple.com, accept pending agreements"
  fi
fi

# ---------------------------------------------------------------------------
# Git tag + GitHub Release
# ---------------------------------------------------------------------------
echo "▶ tagging v$VERSION and pushing…"
git add Info.plist
git -c user.email="release@coshot.dev" -c user.name="coshot release" \
  commit -m "v$VERSION" --allow-empty >/dev/null
git tag -f "v$VERSION"
git push origin main --tags >/dev/null 2>&1

echo "▶ creating GitHub Release…"
gh release delete "v$VERSION" --repo "$GH_REPO" --yes >/dev/null 2>&1 || true
gh release create "v$VERSION" coshot.zip \
  --repo "$GH_REPO" \
  --title "coshot v$VERSION" \
  --notes "Signed & notarized by Ara's Developer ID.

**Install:**
\`\`\`
curl -L -o /tmp/coshot.zip https://github.com/$GH_REPO/releases/download/v$VERSION/coshot.zip
unzip -o /tmp/coshot.zip -d /Applications/
xattr -dr com.apple.quarantine /Applications/coshot.app
open /Applications/coshot.app
\`\`\`

Then click the ⚡ menu bar icon → Set Cerebras API Key.
Press ⌥Space to summon; tap A · S · D · F · G to run a prompt."

echo ""
echo "✓ shipped coshot v$VERSION"
echo "  https://github.com/$GH_REPO/releases/tag/v$VERSION"
