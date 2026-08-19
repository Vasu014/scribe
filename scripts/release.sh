#!/usr/bin/env bash
#
# Scribe release pipeline (SPEC §6: Developer ID signing + notarization +
# Sparkle 2 updates; T9).
#
#   xcodegen → Release build (SUFeedURL baked in, base entitlements NOT injected)
#   → re-sign Sparkle's nested code INNERMOST FIRST, then the .app
#   → verify (codesign --deep --strict) → notarize .app → staple → spctl assess
#   → DMG (hdiutil UDZO) → sign DMG → notarize DMG → staple + validate
#
# Every step is a gate: the script exits non-zero the moment anything fails,
# including a notarytool submission that comes back Invalid (notarytool itself
# exits 0 in that case — see notarize()).
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
set -Eeuo pipefail

cd "$(dirname "$0")/.."

DRY_RUN=0
case "${1-}" in
  --dry-run) DRY_RUN=1 ;;
  -h|--help) sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) echo "error: unknown argument: $1 (try --help)" >&2; exit 2 ;;
esac

# --- failure reporting -------------------------------------------------------
# Anything that escapes a gate lands here. Bare `set -e` is easy to defeat by
# accident (a trailing `| tee`, a `$(...)` in a condition), so every fallible
# step below is ALSO checked explicitly; this trap is the backstop that makes
# the failure loud rather than a silent exit-0 release.
CURRENT_STEP="startup"
LAST_SUBMISSION_ID=""

on_err() {
  local code=$?
  echo >&2
  echo "======================================================================" >&2
  echo "RELEASE FAILED during: ${CURRENT_STEP} (exit ${code})" >&2
  if [[ -n "$LAST_SUBMISSION_ID" ]]; then
    echo "  notarization submission: ${LAST_SUBMISSION_ID}" >&2
    echo "  inspect it with:" >&2
    echo "    xcrun notarytool log ${LAST_SUBMISSION_ID} --keychain-profile ${SCRIBE_NOTARY_PROFILE:-<profile>}" >&2
  fi
  echo "  NOTHING in ${OUT_DIR:-dist}/ should be shipped." >&2
  echo "======================================================================" >&2
  exit "$code"
}
trap on_err ERR

step() { CURRENT_STEP="$1"; echo "==> $1"; }
die()  { echo "error: $*" >&2; exit 1; }

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
  # `${x:+set}${x:-<unset>}` printed "set" AND the value when set, because the
  # second expansion falls through whenever x is non-empty. Only one branch
  # should ever appear.
  echo "    Sparkle Ed25519:    ${SCRIBE_PUBLIC_ED_KEY:-<unset — update verification disabled>}"
  echo "    version/build:      from project / ${BUILD_NUMBER}"
  echo "    1. xcodegen generate"
  echo "    2. xcodebuild -configuration Release (SUFeedURL=<feed>,"
  echo "       SUPUBLIC_ED_KEY=<ed25519>, CFBundleVersion=${BUILD_NUMBER},"
  echo "       CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)"
  echo "    3. codesign innermost-first: Installer.xpc, Downloader.xpc,"
  echo "       Updater.app, Autoupdate, Sparkle.framework, Scribe.app"
  echo "       (each --options runtime --timestamp)"
  echo "    4. codesign --verify --deep --strict Scribe.app + entitlement audit"
  echo "    5. ditto zip → notarytool submit --wait (status must be Accepted)"
  echo "       → stapler staple + validate → spctl --assess (app)"
  echo "    6. hdiutil create -format UDZO → codesign DMG --timestamp"
  echo "    7. notarytool submit --wait → stapler staple + validate (dmg)"
  echo "    output: ${OUT_DIR}/Scribe-<version>.dmg"
  exit 0
fi

for tool in xcodegen xcodebuild hdiutil xcrun codesign plutil ditto spctl; do
  command -v "$tool" >/dev/null || die "'$tool' not found in PATH"
done

mkdir -p "$OUT_DIR"

# --- notarize <path> ---------------------------------------------------------
# `notarytool submit --wait` exits 0 even when the submission comes back
# Invalid or Rejected — the status only lives in the payload. This wrapper is
# the reason the pipeline can no longer report success on a failed release:
# it parses the status and fails hard on anything that is not "Accepted".
notarize() {
  local path="$1" label="$2"
  local json="$OUT_DIR/.notarytool-${label}.json"

  if ! xcrun notarytool submit "$path" \
        --keychain-profile "$SCRIBE_NOTARY_PROFILE" \
        --wait --output-format json >"$json"; then
    echo "error: notarytool submit failed for $label" >&2
    cat "$json" >&2 || true
    return 1
  fi

  local id status
  id="$(plutil -extract id raw -o - -- "$json" 2>/dev/null || echo "")"
  status="$(plutil -extract status raw -o - -- "$json" 2>/dev/null || echo "")"
  LAST_SUBMISSION_ID="$id"

  echo "    submission id: ${id:-<none>}"
  echo "    status:        ${status:-<none>}"

  if [[ "$status" != "Accepted" ]]; then
    echo "error: notarization of $label is '${status:-unknown}', not Accepted" >&2
    echo "  xcrun notarytool log ${id} --keychain-profile ${SCRIBE_NOTARY_PROFILE}" >&2
    xcrun notarytool log "$id" --keychain-profile "$SCRIBE_NOTARY_PROFILE" >&2 2>/dev/null || true
    return 1
  fi
  [[ -n "$id" ]] || { echo "error: could not read submission id for $label" >&2; return 1; }
  rm -f "$json"
}

step "xcodegen"
xcodegen generate

# CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO: Xcode's ProcessProductPackaging step
# otherwise merges `com.apple.security.get-task-allow` (the debug entitlement)
# into whatever App/Scribe.entitlements declares, and Apple rejects that for
# distribution. This is set HERE, on the release invocation only, so Debug
# builds and `make build` keep the injected entitlement they want.
# CODE_SIGNING_ALLOWED=NO: the real signature is applied below, innermost
# first — letting Xcode sign the app first would just be thrown away, and its
# outside-in ordering is what invalidated Sparkle's nested code before.
step "Release build (unsigned; SUFeedURL baked in)"
BUILD_LOG="$OUT_DIR/.xcodebuild-release.log"
if ! xcodebuild -project Scribe.xcodeproj -scheme Scribe -configuration Release \
      -derivedDataPath "$DERIVED" \
      CODE_SIGNING_ALLOWED=NO \
      CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
      DEVELOPMENT_TEAM="$SCRIBE_TEAM_ID" \
      SUFEED_URL="$SCRIBE_FEED_URL" \
      SUPUBLIC_ED_KEY="${SCRIBE_PUBLIC_ED_KEY:-}" \
      CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
      build >"$BUILD_LOG" 2>&1; then
  tail -40 "$BUILD_LOG" >&2
  die "xcodebuild failed — full log: $BUILD_LOG"
fi
tail -3 "$BUILD_LOG"
rm -f "$BUILD_LOG"

APP="$DERIVED/Build/Products/Release/Scribe.app"
[[ -d "$APP" ]] || die "$APP not found — build failed"

# --- signing -----------------------------------------------------------------
# Sparkle ships Autoupdate, Updater.app and the two XPC services pre-signed by
# the Sparkle project (ad-hoc, no team, no timestamp), and SPM does NOT re-sign
# nested bundles inside a binary framework — so notarization saw four binaries
# "not signed with a valid Developer ID certificate". They have to be signed
# explicitly, and INNERMOST FIRST: signing a container seals the hashes of
# everything inside it, so signing outside-in silently invalidates the inner
# signatures. Order and flags follow Sparkle's own distribution documentation
# (https://sparkle-project.org/documentation/sandboxing/), plus --timestamp,
# which notarization requires on every signature.
step "Sign Sparkle's nested code, innermost first"
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_V="$SPARKLE_FW/Versions/B"
[[ -d "$SPARKLE_V" ]] || die "$SPARKLE_V not found — Sparkle layout changed, update this script"

SIGN=(codesign --force --timestamp --options runtime --sign "$SCRIBE_SIGNING_IDENTITY")

"${SIGN[@]}" "$SPARKLE_V/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$SPARKLE_V/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$SPARKLE_V/Updater.app"
"${SIGN[@]}" "$SPARKLE_V/Autoupdate"
"${SIGN[@]}" "$SPARKLE_FW"

step "Sign Scribe.app"
"${SIGN[@]}" --entitlements App/Scribe.entitlements "$APP"

step "Verify signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "Authority|TeamIdentifier|Timestamp|flags"

# The get-task-allow rejection was silent until Apple's servers saw it. Catch
# it locally instead: it costs nothing and turns a 10-minute round trip into an
# immediate failure.
step "Audit entitlements (no get-task-allow)"
if codesign -d --entitlements - --xml "$APP" 2>/dev/null \
     | plutil -convert xml1 -o - - \
     | grep -q "com.apple.security.get-task-allow"; then
  die "Scribe.app requests com.apple.security.get-task-allow — Apple rejects this for distribution"
fi
echo "    clean"

step "Notarize .app (this can take several minutes)"
ZIP="$OUT_DIR/Scribe-notarization.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP" "app"
rm -f "$ZIP"

step "Staple .app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

step "Gatekeeper assessment"
spctl --assess --type execute -vv "$APP"

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
DMG="$OUT_DIR/Scribe-$VERSION.dmg"

step "DMG: $DMG"
rm -f "$DMG"
hdiutil create -volname "Scribe" -srcfolder "$APP" -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$SCRIBE_SIGNING_IDENTITY" "$DMG"
codesign --verify --strict --verbose=2 "$DMG"

step "Notarize DMG"
notarize "$DMG" "dmg"

step "Staple DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

trap - ERR

echo
echo "Done: $DMG (notarized + stapled). Next, update the Sparkle feed:"
echo "  1. find ~/Library/Developer/Xcode/DerivedData -name sign_update -type f"
echo "  2. /path/to/sign_update '$DMG'   # -> sparkle:edSignature=\"…\" length=\"…\""
echo "  3. Add an <item> to distribution/appcast.xml using those values"
echo "     (template entry shows the format), and upload the DMG + appcast."
