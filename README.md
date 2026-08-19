# Scribe

A menu-bar meeting-notes app for macOS. Scribe records the meetings you start,
transcribes them **on your Mac**, and merges the transcript with the notes you
type during the call into structured, cited meeting notes.

It does not join your meetings as a bot, does not upload audio, and never
writes audio to disk. The only thing that leaves your machine is the text sent
to the Anthropic API at the end of a meeting, using your own API key.

**Status: Phase 0 dogfood.** Feature-complete v0, in daily-driver testing. Not
yet signed or notarized — `scripts/release.sh` has the pipeline ready for
signing week. Expect rough edges; see [Known limitations](#known-limitations).

---

## How it works

```
  ┌─ system audio (SCStream) ─┐
  │                           ├─→ WhisperKit ─→ transcript ─┐
  └─ microphone (AVAudio)  ───┘   (on-device)               │
                                                            ├─→ fusion ─→ notes
  scratchpad fragments ─────────────────────────────────────┘   (Anthropic)
  (what you type, timestamped)
```

Two audio channels are captured separately, so the notes can distinguish what
**you** said from what **they** said. Both are transcribed locally with
WhisperKit — no audio leaves the machine and none is retained after
transcription.

While the meeting runs you can jot rough notes in a floating scratchpad
(⌥⌘N). Each note is timestamped against the meeting clock, so fusion knows
*when* you wrote it and can anchor it to what was being discussed.

When you stop, the transcript and your fragments go to Claude, which returns a
title, a summary, decisions and action items — each **required to cite a
timestamp and a verbatim quote**. A deterministic validator then re-checks
every citation against the real transcript and flags any quote it cannot find.
That warning card is the hallucination-audit surface: fusion is not trusted, it
is checked.

---

## Requirements

| | |
|---|---|
| macOS | 14 or later, **Apple Silicon** |
| Permissions | Microphone, and Screen Recording (macOS routes other participants' audio through it) |
| Disk | ~500 MB for the Whisper model |
| API key | An [Anthropic API key](https://console.anthropic.com/) for fusion — stored in your Keychain |

Screen Recording is used for **audio only**. Scribe captures a 2×2-pixel video
stream because the API requires one, and discards every frame.

---

## Install

No signed release yet, so build it yourself:

```bash
brew install xcodegen
git clone https://github.com/Vasu014/scribe.git && cd scribe
scripts/dev.sh                      # generate project, run tests, build
cp -R ~/Library/Developer/Xcode/DerivedData/Scribe-*/Build/Products/Debug/Scribe.app /Applications/
open -a /Applications/Scribe.app
```

Copy it to `/Applications` rather than running from DerivedData: the build is
ad-hoc signed, so **every rebuild changes its identity and invalidates your
Screen Recording grant** — the one permission that costs a quit-and-reopen
cycle each time.

Scribe is an `LSUIElement` app: **no dock icon, no window on launch.** Look for
the waveform glyph in your menu bar.

---

## First run

A setup wizard walks you through, and resumes where it left off if interrupted:

1. **Microphone** — standard prompt.
2. **Screen Recording** — requires quitting and reopening once; macOS only
   applies this grant on relaunch.
3. **Whisper model** — downloads `small.en` (~500 MB) with progress.
4. **API key** — optional at setup; without it meetings still record and
   transcribe, they just cannot be fused into notes.

Re-run it any time with `defaults write com.example.Scribe setupPhase -int 0`.

---

## Using it

| Action | How |
|---|---|
| Start / stop a meeting | Menu bar item → Start / Stop Meeting (⌘. while the menu is open) |
| Open the scratchpad | **⌥⌘N** from anywhere |
| Dismiss the scratchpad | **Esc** — recording continues |
| Stop while fullscreen | Hover the recording chip (top-right) → Stop |
| Read notes | Menu bar → History… |
| Settings | Menu bar → Settings… (⌘,) |

The scratchpad is a floating panel that never steals focus from your meeting
app. Type freely — text is saved as you go, and text you **delete** is
discarded rather than saved. Press Esc to dismiss it; the recording keeps
going and the menu bar keeps showing elapsed time.

When your menu bar is hidden (any fullscreen app), a small **recording chip**
appears top-right instead, showing the elapsed time. Hover it for Stop, click
it to jump to the scratchpad, drag it along the top edge to move it. The
recording indicator is never absent while the mic is live — that is a
deliberate consent guarantee, not a convenience.

After you stop: a spinner while fusion runs (~20 s), then a green **Notes
ready** badge for 4 seconds. Click it to open the notes. On failure you get a
⚠ that persists until you open the menu, and **Retry Fusion** — your transcript
and notes are already saved, so a retry costs nothing but the API call.

---

## Settings

- **Anthropic API Key** — stored in the macOS Keychain, never in a plist.
  Deleting it is undoable for 10 seconds.
- **Whisper Model** — `tiny.en` / `base.en` / `small.en` (default) /
  `large-v3_turbo`. Shows download state and offers Download; applies at the
  next session start, never mid-meeting.
- **Lookback Window** — how far back fusion anchors a fragment in the
  transcript. Anchoring only; raw audio is never retained.
- **Launch at Login**

---

## Privacy

- Audio is processed in memory and **never written to disk** — no recordings,
  no cache, nothing to leak or clean up.
- Transcription is fully on-device (WhisperKit / Core ML).
- Only at fusion time do the **transcript text and your typed notes** go to the
  Anthropic API, with your own key. Nothing is sent if you have no key.
- Everything else lives in a local SQLite database at
  `~/Library/Application Support/Scribe/store.sqlite`.
- Deleting a session deletes its notes, transcript and fragments.

---

## Development

```bash
make build            # xcodegen + xcodebuild, unsigned (CI parity)
make test             # MeetingKitCore package tests
scripts/dev.sh        # all of the above in one shot
```

### Screenshot harness

```bash
make build && scripts/ui-gallery.sh /tmp/shots
```

Launches the app with a seeded in-memory store and captures every surface —
History (notes / transcript / empty), Settings, all three scratchpad states,
the recording chip, the wizard, and all five menu-bar states — to PNG. Built to
make design review evidence-driven, and it earned that immediately: it exposed
a scratchpad text view that had never been able to receive a keystroke.

**It is not a substitute for driving the app.** A screenshot cannot show a dead
button, a frozen clock, or a keystroke landing in the wrong application.

### Debug launch arguments

| Flag | Effect |
|---|---|
| `-debugUseStubCapture YES` | Stub capture engine — no TCC prompts, no hot mic |
| `-setupPhase 5` | Skip the setup wizard |
| `-debugStorePath <path>` | Use a throwaway store |
| `-uiGallery YES` | Run the screenshot gallery instead of the app |

### Architecture

The `App/` target is a thin shell — one file per surface, with all wiring in
`ScribeApp.swift`. Domain logic lives in the local SPM package
`Packages/MeetingKitCore/`: `CaptureKit`, `TranscribeKit`, `ScratchpadKit`,
`FusionKit`, `SessionKit`, `Persistence`.

The load-bearing rule (SPEC §3.1) is that components communicate **only through
the store**. There are no cross-module calls except SessionKit's orchestration
wiring, which keeps the pieces independently testable and lets fusion relocate
server-side later without touching upstream.

---

## Known limitations

- **Sleep/wake does not resume capture.** The mic can stay dead after your Mac
  wakes mid-meeting; a warning banner tells you to stop and start a new one.
  A real fix needs clock-preserving pause/resume in `CaptureKit` (T18) —
  calling `start()` again would re-stamp every later timestamp from zero.
- **No meeting auto-detection.** You start meetings by hand; calendar and
  mic-in-use triggers are roadmap (T16).
- **History is scheduled for deletion** in Phase 3 and is deliberately
  minimally invested in.
- Not signed or notarized; no Dynamic Type support (AppKit limitation).

---

## Docs

| | |
|---|---|
| `SPEC.md` | The product/engineering contract (v1.3) |
| `TASKS.md` | Current work, follow-ups, verification standard |
| `AGENTS.md` | Working rules for coding agents |
| `design/` | UI reference — canvas + renders |
| `.agents/design-spec.md` | Per-element UI acceptance checklist |
| `.agents/audit-*.md`, `ux-accessibility-review.md` | Correctness and UX audits |
| `docs/spikes/` | Platform-risk spike results |
| `scripts/README.md` | Release env contract and signing-week setup |

## Release

Direct download, Developer ID signed and notarized, with Sparkle 2 updates
(SPEC §6). `scripts/release.sh` runs build → sign → notarize → staple → DMG,
taking every secret from environment variables; `--dry-run` prints the plan
without touching anything.
