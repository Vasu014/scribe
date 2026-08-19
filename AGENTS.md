# Scribe — agent instructions

Menu bar meeting-notes app for macOS 14+ (Apple Silicon): records mic + system
audio, transcribes on-device with WhisperKit, fuses the transcript with typed
scratchpad fragments into notes via the Anthropic API. Audio never hits disk.

## Repo map

```
App/                       App shell — one file per surface (LSUIElement, no dock icon)
  ScribeApp.swift          Composition root: store, coordinator, menus, all wiring
  MenuBarController        Status item + NSMenu (5 states)
  ScratchpadPanelController  Non-activating HUD panel (⌥⌘N)
  RecordingChipController  Fullscreen-safe indicator + Stop (design 4a)
  HistoryWindowController  Session list + notes/transcript
  SettingsWindowController / SetupWizardController · UIGallery.swift (dev-only)
Packages/MeetingKitCore/   Local SPM package — the domain
  CaptureKit               SCStream (system audio) + AVAudioEngine (mic)
  TranscribeKit            WhisperKit; shared model, per-channel workers
  ScratchpadKit            FragmentComposer — pending row, burst boundary
  FusionKit                Anthropic provider, NotesValidator, eval cases
  SessionKit               SessionCoordinator — lifecycle, the composition seam
  Persistence              GRDB store + migrations, Keychain
Tests/ScribeAppTests/      App-layer unit tests (see Commands)
design/  Canonical UI reference · .agents/  design-spec.md, reviews, audits
SPEC.md  The contract · TASKS.md  Current work + follow-ups
```

**Load-bearing rule (SPEC §3.1):** components talk ONLY through the store.
No cross-module calls except SessionKit's orchestration wiring.

## Commands

```bash
.agents/setup.sh      # FRESH CLONE → verified build (preflight+test+build); --check
make build            # xcodegen + xcodebuild, unsigned (CI parity)
make test             # package tests  ·  make test-app   # App/ unit tests
scripts/ui-gallery.sh /tmp/shots    # screenshot every surface with fixtures
```

`make test-app` is `xcodebuild test -project Scribe.xcodeproj -scheme Scribe
-destination 'platform=macOS'`; `App/` compiles into the test bundle, so it runs
headless. Parallel agents: add `-derivedDataPath /tmp/dd-<name>`.

Useful launch arguments: `-debugUseStubCapture YES` (no TCC prompts, no hot
mic) · `-setupPhase 5` (skip the wizard) · `-debugStorePath <path>`.

## Working rules

- Read `SPEC.md` for specced behavior and cite sections in code comments.
  `.agents/design-spec.md` is the UI acceptance checklist; native macOS
  components always beat the design's raw hex values.
- **Screenshots are not verification for interaction.** Drive the real app — a
  capture cannot show a dead button, a frozen clock, or a keystroke landing in
  the wrong app; all three shipped past screenshot review. If the environment
  blocks verification, say so; never imply you tested it.
- `swift test` rewrites `Package.resolved`, dropping the Sparkle pin (an
  app-target-only dep). `.agents/setup.sh` restores it; a hand-run does not.
- Do NOT commit. Leave the tree dirty; report files changed, tests, decisions
  and anything skipped — the lead reviews and commits.
