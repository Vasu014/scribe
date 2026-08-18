#!/usr/bin/env bash
#
# Scribe release pipeline (SPEC §6: Developer ID signing + notarization +
# Sparkle 2 updates; T9).
#
#   xcodegen → Release build (Developer ID-signed, SUFeedURL baked in)
#   → verify codesign → notarize .app → staple .app
#   → DMG (hdiutil UDZO) → sign DMG → notarize DMG → staple DMG
#
# No secrets live in this file — everything arrives via environment variables
# (contract below; one-time human setup in scripts/README.md):
#
#   SCRIBE_TEAM_ID            Apple Developer Team ID                 (required)
#   SCRIBE_SIGNING_IDENTITY   "Developer ID Application: NAME (TEAM)" (required)
#   SCRIBE_NOTARY_PROFILE     keychain profile from                  (required)
#                             `xcrun notarytool store-credentials`
#   SCRIBE_FEED_URL           appcast.xml URL → SUFeedURL            (required)
#   SCRIBE_PUBLIC_ED_KEY      Sparkle Ed25519 public key →           (optional
#                             SUPublicEDKey (signing week; App/dsa_pub.pem)  until then)
#   SCRIBE_BUILD_NUMBER       CFBundleVersion (default: git commit count)
#   SCRIBE_OUT_DIR            output directory (default: dist/)
#
# Usage:
#   scripts/release.sh              full release (stops early, listing what is
#                                   missing, if required env vars are unset)
#   scripts/release.sh --dry-run    print the plan, build nothing
#
set -euo pipefail

cd "$(dirname "$0")/.."

DRY_RUN=0
case "${1-}" in
  --dry-run) DRY_RUN=1 ;;
  -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) echo "error: unknown argument: $1 (try --help)" >&2; exit 2 ;;
esac

REQUIRED_VARS=(SCRIBE_TEAM_ID SCRIBE_SIGNING_IDENTITY SCRIBE_NOTARY_PROFILE SCRIBE_FEED_URL)

missing=()
for var in "${REQUIRED_VARS[@]}"; do
  [[ -z "${!var:-}" ]] && missing+=("$var")
done
if (( ${#missing[@]} )) && (( ! DRY_RUN )); then
  {
    echo "error: missing required environment variables:"
    printf '  - %s\n' "${missing[@]}"
    echo
    echo "Nothing was built or submitted. See scripts/README.md for the full"
    echo "env contract and one-time signing setup."
  } >&2
  exit 1
fi

BUILD_NUMBER="${SCRIBE_BUILD_NUMBER:-$(git rev-list --count HEAD)}"
OUT_DIR="${SCRIBE_OUT_DIR:-dist}"
DERIVED="build/release"

if (( DRY_RUN )); then
  echo "==> DRY RUN — plan only, nothing executes"
  echo "    team ID:            ${SCRIBE_TEAM_ID:-<unset>}"
  echo "    signing identity:   ${SCRIBE_SIGNING_IDENTITY:-<unset>}"
  echo "    notary profile:     ${SCRIBE_NOTARY_PROFILE:-<unset>}"
  echo "    Sparkle feed URL:   ${SCRIBE_FEED_URL:-<unset>}"
  echo "    Sparkle Ed25519:    ${SCRIBE_PUBLIC_ED_KEY:+set}${SCRIBE_PUBLIC_ED_KEY:-<unset>}"
  echo "    version/build:      from project / ${BUILD_NUMBER}"
  echo "    1. xcodegen generate"
  echo "    2. xcodebuild -configuration Release (signed, SUFeedURL=<feed>,"
  echo "       SUPUBLIC_ED_KEY=<ed25519>, CFBundleVersion=${BUILD_NUMBER})"
  echo "    3. codesign --verify --strict Scribe.app"
  echo "    4. ditto zip → xcrun notarytool submit --wait → xcrun stapler staple (app)"
  echo "    5. hdiutil create -format UDZO → codesign DMG"
  echo "    6. xcrun notarytool submit --wait → xcrun stapler staple (dmg)"
  echo "    output: ${OUT_DIR}/Scribe-<version>.dmg"
  exit 0
fi

for tool in xcodegen xcodebuild hdiutil xcrun codesign plutil ditto; do
  command -v "$tool" >/dev/null || { echo "error: '$tool' not found in PATH" >&2; exit 1; }
done

mkdir -p "$OUT_DIR"

echo "==> xcodegen"
xcodegen generate

echo "==> Release build (Developer ID, SUFeedURL baked in)"
xcodebuild -project Scribe.xcodeproj -scheme Scribe -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$SCRIBE_TEAM_ID" \
  CODE_SIGN_IDENTITY="$SCRIBE_SIGNING_IDENTITY" \
  SUFEED_URL="$SCRIBE_FEED_URL" \
  SUPUBLIC_ED_KEY="${SCRIBE_PUBLIC_ED_KEY:-}" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  build 2>&1 | tail -20

APP="$DERIVED/Build/Products/Release/Scribe.app"
[[ -d "$APP" ]] || { echo "error: $APP not found — build failed" >&2; exit 1; }

echo "==> Verify signature"
codesign --verify --strict "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Authority|TeamIdentifier" || true

echo "==> Notarize .app (this can take several minutes)"
ditto -c -k --keepParent "$APP" "$OUT_DIR/Scribe-notation.zip"
xcrun notarytool submit "$OUT_DIR/Scribe-notation.zip" \
  --keychain-profile "$SCRIBE_NOTARY_PROFILE" --wait
rm -f "$OUT_DIR/Scribe-notation.zip"
xcrun stapler staple "$APP"

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
DMG="$OUT_DIR/Scribe-$VERSION.dmg"
echo "==> DMG: $DMG"
hdiutil create -volname "Scribe" -srcfolder "$APP" -ov -format UDZO "$DMG"
codesign --sign "$SCRIBE_SIGNING_IDENTITY" "$DMG"

echo "==> Notarize DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$SCRIBE_NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo
echo "Done: $DMG (notarized + stapled). Next, update the Sparkle feed:"
echo "  1. find ~/Library/Developer/Xcode/DerivedData -name sign_update -type f"
echo "  2. /path/to/sign_update '$DMG'   # -> sparkle:edSignature=\"…\" length=\"…\""
echo "  3. Add an <item> to distribution/appcast.xml using those values"
echo "     (template entry shows the format), and upload the DMG + appcast."
