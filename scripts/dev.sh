#!/usr/bin/env bash
#
# One-command contributor setup (T9): generate the Xcode project, run the
# MeetingKitCore package tests, then build the app (unsigned, as in CI).
#
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> xcodegen generate"
xcodegen generate

echo "==> swift test (Packages/MeetingKitCore)"
(cd Packages/MeetingKitCore && swift test)

echo "==> make build (app, unsigned)"
make build
