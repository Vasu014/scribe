# Spike 1 — SCStream + AVAudioEngine coexistence (SPEC §7)

**Status:** ⏳ PENDING — code landed (T4), runtime validation is manual
(hardware + TCC prompts; the code compiles headless, `swift test` covers only
the PCM conversion math). Owner: Engineer A. Blocks: T10 dogfood hardening.

**Risk being retired (SPEC §7, the #1 platform risk):** activating SCK audio
capture while an AVAudioEngine input tap runs can silently kill the mic stream
(or vice versa) on macOS 14.x; voice processing (VP) worsens it on some builds.

**Success:** both streams stable for 10+ minutes, device-switch survival
(AirPods disconnect/reconnect mid-run), across both machines' macOS point
releases.

## Test matrix — 8 runs × 10+ min (SPEC §7)

Fill `Result` (stable / mic died / remote died / glitch notes) and `Notes`
(any observable interference, VP artifacts, restart-ladder firings from the
session `device_events` log). Record the exact macOS build (`sw_vers` output)
per machine.

| # | Start order | Voice processing | Machine | macOS build | Result | Notes |
|---|-------------|------------------|---------|-------------|--------|-------|
| 1 | SCStream first | ON  | Machine 1 |             | ☐ | |
| 2 | SCStream first | OFF | Machine 1 |             | ☐ | |
| 3 | Engine first   | ON  | Machine 1 |             | ☐ | |
| 4 | Engine first   | OFF | Machine 1 |             | ☐ | |
| 5 | SCStream first | ON  | Machine 2 |             | ☐ | |
| 6 | SCStream first | OFF | Machine 2 |             | ☐ | |
| 7 | Engine first   | ON  | Machine 2 |             | ☐ | |
| 8 | Engine first   | OFF | Machine 2 |             | ☐ | |

## How to run a cell

Both knobs are code-level (no UI yet):

1. **Start order** — flip `SCKCaptureEngine.Configuration.startOrder`
   (default `SCKCaptureEngine.defaultStartOrder` = the current hypothesis
   `.screenCaptureKitFirst`, SPEC §4.1) — or just run the harness below
   with `--order sck|mic`.
2. **Voice processing** — construct the engine with
   `SCKCaptureEngine.Configuration(voiceProcessingEnabled: false)`
   (harness: `--vp off`).
3. Build & run a debug harness (or the app once T5 lands) with both
   permissions granted; start a meeting; play audio on the machine (remote
   channel must have signal) and speak into the mic (local channel).
4. Watch both channels' sample flow for 10+ minutes (log `onAudio` counts per
   channel per minute). Mid-run: disconnect + reconnect AirPods
   (device-switch survival). Then end the session.
5. Record results above; if a cell fails, note whether the silent-restart /
   mic-only degradation ladder fired correctly (SPEC §4.1 failure modes).

## Outcome → code

Whichever cell(s) pass on BOTH machines decides:

- `SCKCaptureEngine.startOrder` — set to the winning order permanently.
- VP default in `Configuration` — if VP ON fails in every stable cell,
  default to `false` (SPEC §4.1: fall back to VP off, accept partial bleed).
- Record the tested macOS build numbers in the doc comment next to
  `startOrder` (SPEC §4.1: "Whatever the spike finds becomes a code comment
  with the macOS build numbers tested").

## Fallback ladder (SPEC §7, in order)

1. **Fixed start order** — reorder engine activation (cheap, no quality cost).
2. **Voice processing off** — accept partial bleed; channel separation
   survives on level differences (me/them stays useful).
3. **Same-engine mic restructure** — capture the mic through an alternate
   graph arrangement (e.g. AVAudioEngine SinkNode / single-engine-only
   capture path). Structural work; only if 1–2 fail.

## Degradation behavior already wired (independent of the matrix)

- Screen Recording permission missing/revoked → mic-only
  (`remoteStreamActive == false`), reason surfaced via `onRemoteDegraded`.
- SCStream error/stall mid-session → ONE silent restart; second failure →
  mic-only (SPEC §4.1).
- Device change (route change / default-input change) → engine graph rebuilt
  in place; session clock keeps running; `onDeviceChange` fires so the
  coordinator logs `deviceChanged` (T2 seam).

## Machine 1 harness

`Tools/SpikeHarness` (standalone SPM executable, path-depends on
MeetingKitCore → CaptureKit) drives one matrix cell;
`scripts/spike1-run.sh` orchestrates the matrix. The harness binary itself
is generic — Machine 2 can reuse it verbatim (only the results file name
differs).

### How to run (in order)

1. **Build**: `cd Tools/SpikeHarness && swift build`
2. **Probe permissions** (no run): `cd Tools/SpikeHarness && swift run
   SpikeHarness -- --probe`. CLI tools inherit the TCC identity of their
   *responsible* app (the terminal/editor), so grants land on that app.
   Mic: exit 10 = denied (after prompting). Screen: exit 11 = not granted
   (after `CGRequestScreenCaptureAccess()`). Screen grants need the
   responsible app quit & reopened, then RERUN the probe.
3. **Smoke** (sanity, 4 × 90 s): `scripts/spike1-run.sh --smoke`
4. **Full matrix** (4 × 600 s, default): `scripts/spike1-run.sh` (or
   `--full`, `--duration N` override, `--only sck-first:vp-on` for one cell).
   The script preflights permissions first (probe ×3, 30 s apart) and
   refuses to start runs without them. Ctrl-C ends a combo early with a
   partial-run verdict. Mid-run, do the AirPods disconnect/reconnect pass
   (device-switch survival shows up as `deviceChanges` + gaps).
5. **Summarize**: `scripts/spike1-run.sh --summarize` — aligned table plus
   ready-to-paste markdown rows for the matrix above.

### What the harness does per run

- System audio comes from a **child `afplay` process** looping a hand-built
  30 s WAV (440 Hz, 0.5 Hz amplitude modulation, low volume) — the engine
  sets `excludesCurrentProcessAudio`, so the harness's own audio would be
  excluded.
- With `--vp on`, a throwaway never-started engine probes
  `setVoiceProcessingEnabled(true)` before the real run; failure lands in
  the verdict as `swiftRuntimeNote` (the real engine silently falls back to
  VP off — SPEC §7 rung 2 — and does not surface it).
- stderr: plain-English progress every 30 s + JSONL timeline snapshots
  every 10 s. stdout: exactly ONE line of verdict JSON.

### What `ok` means

Both channels delivered **≥ 50 buffers**, first buffer **< 5 s** after
session start, max inter-buffer gap **< 10 s** (only while the channel was
delivering), and `onRemoteDegraded` never fired. A silent channel with no
degradation event (the bug class this spike hunts) fails on buffer count.

### Where results land

`docs/spikes/spike1-results-machine1.jsonl` — one verdict JSON line per
combo, labeled `<combo>@<macos-build>` (build from `sw_vers`). The matrix
table above stays empty until the lead fills it from `--summarize` output.
