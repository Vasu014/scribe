# Scribe — agent instructions

Menu bar meeting-notes app for macOS 14+ (Apple Silicon). Local-only, on-device
transcription, LLM fusion of transcript + timestamped fragments.

## Read before working
1. `SPEC.md` (v1.3) — the contract. Section citations (e.g. "SPEC §4.5") belong in code
   comments wherever you implement specced behavior.
2. `TASKS.md` — the current task list; your task's row says what "done" means.
3. `design/README.md` + `design/Menu Bar App Designs.dc.html` — canonical UI reference
   (native system components always win over the HTML's hex values).

## Layout
- `App/` — thin app shell (menu bar app, LSUIElement). UI surfaces live here.
- `Packages/MeetingKitCore/` — local SPM package: CaptureKit, TranscribeKit,
  ScratchpadKit, FusionKit, SessionKit, Persistence.
- Architectural rule (SPEC §3.1, load-bearing): components communicate ONLY through the
  store (Persistence). No cross-module calls except SessionKit's orchestration wiring.

## Build & test
- Package: `cd Packages/MeetingKitCore && swift build && swift test`
- App: `make build` (xcodegen + xcodebuild, signing disabled locally)
- Swift 5 language mode; keep `swift build` warning-free. All new public API needs doc
  comments. GRDB 7 patterns are already established in `Persistence/MeetingStore.swift`.

## Git discipline
- Do NOT commit — the lead reviews diffs and commits. Leave the working tree with your
  changes, `swift test`/`make build` green, and report: files changed, test results,
  decisions made, anything you skipped.
