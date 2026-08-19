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
  SettingsWindowController / SetupWizardController
  UIGallery.swift          Dev-only screenshot harness (-uiGallery YES)
Packages/MeetingKitCore/   Local SPM package — the domain
  CaptureKit               SCStream (system audio) + AVAudioEngine (mic)
  TranscribeKit            WhisperKit; shared model, per-channel workers
  ScratchpadKit            FragmentComposer — pending row, burst boundary
  FusionKit                Anthropic provider, NotesValidator, eval cases
  SessionKit               SessionCoordinator — lifecycle, the composition seam
  Persistence              GRDB store + migrations, Keychain
design/                    Canonical UI reference (canvas HTML + renders)
.agents/                   design-spec.md (acceptance checklist), reviews, audits
SPEC.md                    The contract · TASKS.md  Current work + follow-ups
```

**Load-bearing rule (SPEC §3.1):** components talk ONLY through the store.
No cross-module calls except SessionKit's orchestration wiring.

## Commands

```bash
make build            # xcodegen + xcodebuild, unsigned (CI parity)
make test             # package tests  (139 at time of writing)
scripts/dev.sh        # generate + test + build in one shot
scripts/ui-gallery.sh /tmp/shots    # screenshot every surface with fixtures
```

Build a single target without touching the shared project (parallel agents):
`xcodebuild -project Scribe.xcodeproj -scheme Scribe build CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/dd-<name>`

Useful launch arguments: `-debugUseStubCapture YES` (no TCC prompts, no hot
mic) · `-setupPhase 5` (skip the wizard) · `-debugStorePath <path>`.

## Working rules

- Read `SPEC.md` for specced behavior and cite sections in code comments.
  `.agents/design-spec.md` is the UI acceptance checklist; native macOS
  components always beat the design's raw hex values.
- **Screenshots are not verification for interaction.** Drive the real app —
  a capture cannot show a dead button, a frozen clock, or a keystroke landing
  in the wrong application. All three shipped past screenshot review.
  If the environment blocks verification, say so; never imply you tested it.
- `swift test` rewrites `Package.resolved` and drops the Sparkle pin (an
  app-target-only dep). Check `git diff` afterwards and restore it.
- Do NOT commit. Leave the tree dirty; report files changed, tests, decisions,
  and anything skipped. The lead reviews and commits.
