#!/usr/bin/env bash
#
# ui-gallery.sh — screenshot every Scribe UI surface into PNGs for visual
# diffing against design/ (dev tooling; see App/UIGallery.swift).
#
#   ./scripts/ui-gallery.sh [OUT_DIR]      # default OUT_DIR: /tmp/scribe-ui
#
# Launches the DEBUG build with `-uiGallery YES`, reads the
# `GALLERY<TAB>scene<TAB>value` lines it prints, captures each scene and
# kills the app. `value` is a window number (window capture), an `x,y,w,h`
# region (screen capture), or `file:<path>` for a scene the app rendered to
# a PNG itself — `menubar-states` does that, because the status item can
# only be region-captured and comes back black when the menu bar auto-hides.
#
# Requires the Screen Recording permission for whatever runs this (Terminal,
# iTerm, the agent host…); without it screencapture writes black or nothing
# and the size check below fails. `menubar-states` needs none of that — the
# app draws it — so a black `menubar-region` is a warning, not a failure.
set -euo pipefail

OUT_DIR="${1:-/tmp/scribe-ui}"
TIMEOUT_SECONDS="${GALLERY_TIMEOUT:-60}"
MIN_PNG_BYTES="${GALLERY_MIN_BYTES:-3000}"

die() { echo "ui-gallery: $*" >&2; exit 1; }

command -v screencapture >/dev/null || die "screencapture not found (macOS only)"

# --- Locate the built app --------------------------------------------------
# SCRIBE_APP overrides the search — set it when the app was built with an
# explicit -derivedDataPath (CI, or a scratch build) rather than into the
# default DerivedData location.
APP="${SCRIBE_APP:-}"
if [ -n "$APP" ]; then
    [ -d "$APP" ] || die "SCRIBE_APP does not exist: $APP"
fi
if [ -z "$APP" ]; then
    while IFS= read -r candidate; do
        APP="$candidate"
        break
    done < <(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/Scribe-*/Build/Products/Debug/Scribe.app 2>/dev/null || true)
fi

[ -n "$APP" ] || die "no built Scribe.app under ~/Library/Developer/Xcode/DerivedData — run 'make build' first, or set SCRIBE_APP"
BIN="$APP/Contents/MacOS/Scribe"
[ -x "$BIN" ] || die "app binary missing or not executable: $BIN"

mkdir -p "$OUT_DIR"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/scribe-ui-gallery.XXXXXX")"
LOG="$WORK/gallery.log"
ERR="$WORK/gallery.err"

APP_PID=""
cleanup() {
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "ui-gallery: app     $APP"
echo "ui-gallery: output  $OUT_DIR"

# The app is launched DIRECTLY (not via `open`) so its stdout is this pipe.
"$BIN" -uiGallery YES >"$LOG" 2>"$ERR" &
APP_PID=$!

# --- Wait for the gallery lines -------------------------------------------
# `menubar-region` is printed last, so it terminates the handshake.
deadline=$((SECONDS + TIMEOUT_SECONDS))
until grep -q $'^GALLERY\tmenubar-region\t' "$LOG" 2>/dev/null; do
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        echo "--- app stdout ---" >&2; cat "$LOG" >&2
        echo "--- app stderr ---" >&2; cat "$ERR" >&2
        die "the app exited before printing its gallery lines"
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
        echo "--- app stdout ---" >&2; cat "$LOG" >&2
        echo "--- app stderr ---" >&2; cat "$ERR" >&2
        die "timed out after ${TIMEOUT_SECONDS}s waiting for GALLERY lines"
    fi
    sleep 0.2
done

if [ -s "$ERR" ]; then
    echo "ui-gallery: app stderr:" >&2
    sed 's/^/  /' "$ERR" >&2
fi

# Let the last window finish drawing before the first capture.
sleep 0.5

# --- Capture ---------------------------------------------------------------
captured=0
failed=0
while IFS=$'\t' read -r tag scene value; do
    [ "$tag" = "GALLERY" ] || continue
    [ -n "${scene:-}" ] && [ -n "${value:-}" ] || continue
    out="$OUT_DIR/$scene.png"
    rm -f "$out"
    if [ "${value#file:}" != "$value" ]; then
        # The app already rendered this scene to a PNG (see UIGallery's
        # `menubar-states`) — nothing to capture, just collect it.
        src="${value#file:}"
        cp "$src" "$out" 2>/dev/null || true
    elif [ "$scene" = "menubar-region" ]; then
        # -R<x,y,w,h> in top-left screen coordinates (points). The status
        # item is not an app window, so it can only be region-captured —
        # which means it comes out black if the menu bar is hidden (System
        # Settings › Control Center › "Automatically hide and show the menu
        # bar" must be off) or if another window covers that strip.
        screencapture -x -R"$value" "$out" || true
        echo "ui-gallery: note — menubar-region is a screen-region shot; it is only" \
             "meaningful with the menu bar visible (auto-hide off)."
    else
        # -l<windowNumber>: that window's own image; -o drops the shadow.
        screencapture -o -x -l "$value" "$out" || true
    fi
    # menubar-region depends on the user's menu-bar auto-hide setting and on
    # nothing covering the strip; menubar-states is the reliable substitute,
    # so a thin/absent region shot only warns.
    if [ "$scene" = "menubar-region" ]; then level="WARN"; else level="FAILED"; fi
    if [ ! -f "$out" ]; then
        echo "ui-gallery: $level $scene (no file written)" >&2
        [ "$level" = "WARN" ] || failed=$((failed + 1))
        continue
    fi
    bytes=$(stat -f%z "$out")
    if [ "$bytes" -lt "$MIN_PNG_BYTES" ]; then
        echo "ui-gallery: $level $scene (${bytes} bytes < ${MIN_PNG_BYTES} — blank or missing capture?)" >&2
        [ "$level" = "WARN" ] || failed=$((failed + 1))
        continue
    fi
    printf 'ui-gallery: %-24s %8d bytes  %s\n' "$scene" "$bytes" "$out"
    captured=$((captured + 1))
done < <(grep $'^GALLERY\t' "$LOG")

[ "$captured" -gt 0 ] || die "no scenes captured"
[ "$failed" -eq 0 ] || die "$failed scene(s) failed to capture"

echo "ui-gallery: $captured scene(s) written to $OUT_DIR"
