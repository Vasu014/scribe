# Scribe

Menu-bar meeting-notes app for macOS 14+ (Apple Silicon). Scribe records the
microphone and system audio of meetings you start, transcribes both channels
on-device with WhisperKit, and fuses the transcript with timestamped
scratchpad fragments (an Anthropic LLM call) into titled meeting notes.
Everything is local: audio never leaves the Mac and is never written to disk.

**Status:** Phase 0 dogfood build — feature-complete v0 undergoing daily-driver
dogfooding (see `TASKS.md`). Not signed/notarized yet; `scripts/release.sh`
has the pipeline ready for signing week.

## Layout

```
App/                      App shell (menu bar, Settings, scratchpad, History, wizard)
Packages/MeetingKitCore/  Local SPM package — CaptureKit, TranscribeKit,
                          ScratchpadKit, FusionKit, SessionKit, Persistence
design/                   Canonical UI reference (HTML mockups + README)
docs/spikes/              Week-1 spike write-ups
distribution/             Sparkle appcast template
scripts/                  dev.sh, release.sh (+ env contract README)
SPEC.md                   The contract (v1.3)
```

Architectural rule (SPEC §3.1): components communicate only through the store
(Persistence); the App target is a thin shell.

## Development

Requirements: Xcode 26+, macOS 14+ (Apple Silicon), and
[`xcodegen`](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
scripts/dev.sh        # xcodegen + package tests + app build
```

or step by step:

```bash
xcodegen generate                          # regenerates Scribe.xcodeproj (gitignored)
(cd Packages/MeetingKitCore && swift test) # package tests
make build                                 # unsigned app build (CI parity)
```

## Release / distribution

Direct download, Developer ID signed + notarized, Sparkle 2 updates (SPEC §6).
`scripts/release.sh` runs the full pipeline (build → sign → notarize → staple
→ DMG → staple) with every secret taken from environment variables —
`scripts/README.md` documents the env contract (`SCRIBE_TEAM_ID`,
`SCRIBE_SIGNING_IDENTITY`, `SCRIBE_NOTARY_PROFILE`, `SCRIBE_FEED_URL`, …) and
the one-time signing-week setup including Sparkle Ed25519 key generation.
`scripts/release.sh --dry-run` prints the plan without touching anything.

## Docs

- `SPEC.md` — full product/engineering contract
- `design/` — UI reference
- `docs/spikes/` — platform-risk spike results
- `TASKS.md` — current build-out status
