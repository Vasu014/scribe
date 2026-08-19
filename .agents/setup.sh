#!/usr/bin/env bash
#
# setup.sh — bare checkout → "I can build, test and verify changes", for
# CODING AGENTS. Non-interactive, idempotent, safe to re-run.
#
#   .agents/setup.sh              # preflight + package tests + app build
#   .agents/setup.sh --check      # preflight only (no compiling, ~2s)
#   .agents/setup.sh --no-test    # skip package tests, just build
#   .agents/setup.sh --no-build   # preflight + tests, no app build
#   .agents/setup.sh --no-install # never install anything; fail with the fix command
#   .agents/setup.sh --derived-data /tmp/dd-me   # isolated build (parallel agents)
#
# Why this exists next to scripts/dev.sh: dev.sh is the contributor one-liner
# (xcodegen + swift test + make build) and assumes a working toolchain. This
# adds the things an agent on a fresh clone actually needs — toolchain
# preflight with exact fix commands, a guard around the `swift test`
# Package.resolved/Sparkle trap (AGENTS.md), isolated DerivedData for parallel
# agents, and a verification summary instead of a list of installs.
#
# What it deliberately does NOT do: download the ~500 MB Whisper model or set
# an Anthropic API key. Both are user-level concerns; you can build, test and
# screenshot every UI surface without either. It reports their status only.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PKG="$ROOT/Packages/MeetingKitCore"
RESOLVED="$PKG/Package.resolved"
LOG_DIR="${TMPDIR:-/tmp}"; LOG_DIR="${LOG_DIR%/}/scribe-setup"
mkdir -p "$LOG_DIR"

DO_PROJECT=1
DO_TESTS=1
DO_BUILD=1
ALLOW_INSTALL=1
DERIVED_DATA=""

READY=()
SKIPPED=()
APP_PATH=""

say()  { printf '==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '    WARN: %s\n' "$*" >&2; }
die()  { printf '\nsetup: %s\n' "$1" >&2; shift; for l in "$@"; do printf '       %s\n' "$l" >&2; done; exit 1; }

usage() {
    sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^#\{1,2\} \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --check)        DO_PROJECT=0; DO_TESTS=0; DO_BUILD=0 ;;
        --no-test)      DO_TESTS=0 ;;
        --no-build)     DO_BUILD=0 ;;
        --no-install)   ALLOW_INSTALL=0 ;;
        --derived-data) DERIVED_DATA="${2:?--derived-data needs a path}"; shift ;;
        -h|--help)      usage ;;
        *) die "unknown option: $1" "run: .agents/setup.sh --help" ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# 1. Preflight — the things that produce baffling failures three steps later.
# ---------------------------------------------------------------------------
say "preflight"

[ -f "$ROOT/project.yml" ] || die "not a Scribe checkout (no project.yml at $ROOT)"

os_major="$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)" || die "not macOS — Scribe is a macOS 14+ app"
[ "${os_major:-0}" -ge 14 ] || die "macOS $(sw_vers -productVersion) is too old (SPEC: macOS 14+)" \
    "no fix from here: this checkout cannot be built on this machine"
note "macOS $(sw_vers -productVersion) ok"

arch="$(uname -m)"
if [ "$arch" != "arm64" ]; then
    die "architecture is $arch, Scribe is Apple Silicon only (project.yml ARCHS: [arm64], WhisperKit/CoreML)" \
        "if this is a Rosetta shell, re-run under: arch -arm64 zsh"
fi
note "Apple Silicon ok"

dev_dir="$(xcode-select -p 2>/dev/null || true)"
if [ -d /Applications/Xcode.app ]; then
    xcode_fix="sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
else
    xcode_fix="install Xcode (App Store), then: sudo xcode-select -s /path/to/Xcode.app/Contents/Developer"
fi
case "$dev_dir" in
    "")  die "no developer directory selected" "fix: $xcode_fix" ;;
    */CommandLineTools*)
        die "xcode-select points at the Command Line Tools ($dev_dir), not Xcode" \
            "xcodebuild cannot build a macOS app target from there." \
            "fix: $xcode_fix" ;;
esac
[ -d "$dev_dir" ] || die "xcode-select points at a missing directory: $dev_dir" "fix: $xcode_fix"

if ! xcb_out="$(xcodebuild -version 2>&1)"; then
    case "$xcb_out" in
        *license*) die "the Xcode license has not been accepted" "fix: sudo xcodebuild -license accept" ;;
        *) die "xcodebuild is not usable: ${xcb_out%%$'\n'*}" "fix: $xcode_fix" ;;
    esac
fi
xcode_ver="$(printf '%s' "$xcb_out" | head -1 | awk '{print $2}')"
note "Xcode $xcode_ver at $dev_dir"
# Swift 5.10 + macOS 14 SDK ⇒ Xcode 15.3 is the floor.
case "$xcode_ver" in
    1[0-4].*|15.[0-2]*) warn "Xcode $xcode_ver predates 15.3; project.yml asks for SWIFT_VERSION 5.10 — expect build errors" ;;
esac

# xcodegen — genuinely blocking: Scribe.xcodeproj is gitignored and generated.
if command -v xcodegen >/dev/null 2>&1; then
    note "xcodegen $(xcodegen --version 2>/dev/null | tail -1) ok"
else
    if [ "$ALLOW_INSTALL" -eq 1 ] && command -v brew >/dev/null 2>&1; then
        say "xcodegen missing — installing it with Homebrew (this is the one thing this script installs)"
        brew install xcodegen
        command -v xcodegen >/dev/null 2>&1 || die "brew install xcodegen did not put xcodegen on PATH"
        READY+=("xcodegen installed via Homebrew")
    else
        die "xcodegen is missing and required (Scribe.xcodeproj is gitignored and generated from project.yml)" \
            "fix: brew install xcodegen" \
            "(no Homebrew? see https://github.com/yonaskolb/XcodeGen#installing)"
    fi
fi
READY+=("toolchain: macOS $(sw_vers -productVersion) / $arch / Xcode $xcode_ver / xcodegen")

# ---------------------------------------------------------------------------
# 2. Package.resolved guard (AGENTS.md): `swift test` in Packages/MeetingKitCore
#    rewrites Package.resolved and drops the Sparkle pin, because Sparkle is an
#    app-target-only dependency that only xcodebuild resolves. Snapshot now,
#    restore on the way out — including on failure.
# ---------------------------------------------------------------------------
RESOLVED_SNAPSHOT=""
RESTORED_PIN=0
if [ -f "$RESOLVED" ]; then
    if grep -q '"sparkle"' "$RESOLVED"; then
        RESOLVED_SNAPSHOT="$LOG_DIR/Package.resolved.snapshot"
        cp "$RESOLVED" "$RESOLVED_SNAPSHOT"
    elif git -C "$ROOT" show HEAD:Packages/MeetingKitCore/Package.resolved 2>/dev/null | grep -q '"sparkle"'; then
        # Not this run's doing — someone already ran swift test by hand.
        warn "Package.resolved has ALREADY lost the Sparkle pin in this working tree (someone ran swift test)."
        warn "not touching it — restore with: git checkout Packages/MeetingKitCore/Package.resolved"
    fi
fi

restore_resolved() {
    [ -n "$RESOLVED_SNAPSHOT" ] || return 0
    [ -f "$RESOLVED" ] || return 0
    if ! grep -q '"sparkle"' "$RESOLVED"; then
        cp "$RESOLVED_SNAPSHOT" "$RESOLVED"
        RESTORED_PIN=1
    fi
}
trap restore_resolved EXIT

# ---------------------------------------------------------------------------
# 3. Generate the Xcode project (skipped when already newer than project.yml).
# ---------------------------------------------------------------------------
say "xcode project"
if [ "$DO_PROJECT" -eq 0 ]; then
    if [ -d "$ROOT/Scribe.xcodeproj" ]; then
        note "Scribe.xcodeproj exists (--check: not regenerating)"
        READY+=("Scribe.xcodeproj present")
    else
        note "Scribe.xcodeproj absent — run without --check, or: make project"
        SKIPPED+=("Scribe.xcodeproj generation (--check)")
    fi
elif [ -d "$ROOT/Scribe.xcodeproj" ] && [ "$ROOT/Scribe.xcodeproj/project.pbxproj" -nt "$ROOT/project.yml" ]; then
    note "Scribe.xcodeproj is up to date with project.yml — skipping xcodegen"
else
    xcodegen generate >"$LOG_DIR/xcodegen.log" 2>&1 || {
        tail -20 "$LOG_DIR/xcodegen.log" >&2
        die "xcodegen generate failed (full log: $LOG_DIR/xcodegen.log)"
    }
    note "generated Scribe.xcodeproj from project.yml"
fi
if [ "$DO_PROJECT" -eq 1 ]; then READY+=("Scribe.xcodeproj in sync with project.yml"); fi

# ---------------------------------------------------------------------------
# 4. Package tests — also the SPM resolution warm-up (GRDB + WhisperKit).
# ---------------------------------------------------------------------------
TEST_SUMMARY=""
if [ "$DO_TESTS" -eq 1 ]; then
    say "package tests (Packages/MeetingKitCore) — a cold first run also resolves GRDB + WhisperKit"
    if (cd "$PKG" && swift test) >"$LOG_DIR/swift-test.log" 2>&1; then
        TEST_SUMMARY="$(grep -Eo 'Executed [0-9]+ tests?, with [0-9]+ failures?' "$LOG_DIR/swift-test.log" | tail -1 || true)"
        [ -n "$TEST_SUMMARY" ] || TEST_SUMMARY="$(grep -Eo '[0-9]+ tests? passed' "$LOG_DIR/swift-test.log" | tail -1 || true)"
        [ -n "$TEST_SUMMARY" ] || TEST_SUMMARY="passed"
        note "$TEST_SUMMARY"
        READY+=("package tests green — $TEST_SUMMARY")
    else
        tail -30 "$LOG_DIR/swift-test.log" >&2
        restore_resolved
        die "package tests failed (full log: $LOG_DIR/swift-test.log)" \
            "re-run just the tests with: cd Packages/MeetingKitCore && swift test"
    fi
    restore_resolved
else
    SKIPPED+=("package tests (--no-test/--check)")
fi

# ---------------------------------------------------------------------------
# 5. App build — CI parity, and the real proof the toolchain works.
# ---------------------------------------------------------------------------
if [ "$DO_BUILD" -eq 1 ]; then
    build_args=(-project Scribe.xcodeproj -scheme Scribe build CODE_SIGNING_ALLOWED=NO)
    if [ -n "$DERIVED_DATA" ]; then
        build_args+=(-derivedDataPath "$DERIVED_DATA")
        say "app build (unsigned) into $DERIVED_DATA"
    else
        say "app build (unsigned) — resolves Sparkle on top of the package deps"
    fi
    if xcodebuild "${build_args[@]}" >"$LOG_DIR/xcodebuild.log" 2>&1; then
        note "BUILD SUCCEEDED"
        READY+=("app builds unsigned (make build parity)")
    else
        grep -E 'error:|BUILD FAILED' "$LOG_DIR/xcodebuild.log" | tail -20 >&2 || tail -30 "$LOG_DIR/xcodebuild.log" >&2
        die "app build failed (full log: $LOG_DIR/xcodebuild.log)" \
            "re-run with: make build"
    fi
    # Ask xcodebuild where it actually put the app — a find(1) over DerivedData
    # picks the wrong Scribe.app when several checkouts/worktrees exist.
    settings_args=(-project Scribe.xcodeproj -scheme Scribe -showBuildSettings)
    if [ -n "$DERIVED_DATA" ]; then settings_args+=(-derivedDataPath "$DERIVED_DATA"); fi
    products="$(xcodebuild "${settings_args[@]}" 2>/dev/null \
        | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')"
    if [ -n "${products:-}" ] && [ -d "$products/Scribe.app" ]; then
        APP_PATH="$products/Scribe.app"
        note "Scribe.app: $APP_PATH"
    fi
else
    SKIPPED+=("app build (--no-build/--check)")
fi

# ---------------------------------------------------------------------------
# 6. Report the user-level things — never install them.
# ---------------------------------------------------------------------------
MODEL_DIR="$HOME/Library/Application Support/Scribe/models"
if [ -d "$MODEL_DIR" ] && [ -n "$(ls -A "$MODEL_DIR" 2>/dev/null)" ]; then
    READY+=("Whisper model present ($(du -sh "$MODEL_DIR" 2>/dev/null | cut -f1) in $MODEL_DIR)")
else
    SKIPPED+=("Whisper model (~500 MB) — not needed to build, test or screenshot. Meetings will NOT transcribe without it; get it from the app's setup wizard.")
fi
SKIPPED+=("Anthropic API key — Keychain, user-level. Not needed to build or test; fusion is a no-op without it.")

# ---------------------------------------------------------------------------
# 7. Summary — what is actually verified, and the commands you will use.
# ---------------------------------------------------------------------------
if [ "$RESTORED_PIN" -eq 1 ]; then warn "swift test dropped the Sparkle pin from Package.resolved; restored it (AGENTS.md)"; fi

printf '\n%s\n' "──────────────────────────────────────────────────────────────"
printf 'READY\n'
for l in "${READY[@]}"; do printf '  ✓ %s\n' "$l"; done
printf '\nSKIPPED\n'
for l in "${SKIPPED[@]}"; do printf '  – %s\n' "$l"; done

cat <<EOF

COMMANDS YOU WILL ACTUALLY USE
  make build                                   xcodegen + unsigned build (CI parity)
  cd Packages/MeetingKitCore && swift test     package tests — then check \`git diff Package.resolved\`
  .agents/setup.sh --no-test                   re-verify the build after a toolchain change
  scripts/ui-gallery.sh /tmp/shots             screenshot every surface (needs Screen Recording)

TRAPS (AGENTS.md)
  · swift test rewrites Package.resolved and drops the Sparkle pin (app-target-only dep).
    This script restores it; if you run swift test by hand, check git diff afterwards.
  · Parallel agents: never share DerivedData. Build with
      xcodebuild -project Scribe.xcodeproj -scheme Scribe build CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/dd-<name>
    or .agents/setup.sh --derived-data /tmp/dd-<name>
  · Drive the app with no TCC prompts and no hot mic:
      open -n ${APP_PATH:-<Scribe.app>} --args -debugUseStubCapture YES -setupPhase 5 -debugStorePath /tmp/scribe-<name>.sqlite
  · Screenshots are NOT verification for interaction. A capture cannot show a dead
    button, a frozen clock, or a keystroke landing in the wrong app. Drive the real app.
  · Do NOT commit. Leave the tree dirty and report what changed.
EOF
if grep -q 'ScribeAppTests' "$ROOT/project.yml" 2>/dev/null; then
    printf '\n  App-target tests exist in project.yml — run them with:\n    xcodebuild -project Scribe.xcodeproj -scheme Scribe test CODE_SIGNING_ALLOWED=NO\n'
fi
printf '\nlogs: %s\n' "$LOG_DIR"
