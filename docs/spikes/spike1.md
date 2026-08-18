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

1. **Start order** — flip `SCKCaptureEngine.startOrder`
   (`Sources/CaptureKit/SCKCaptureEngine.swift`, currently the default
   hypothesis `.screenCaptureKitFirst`, SPEC §4.1).
2. **Voice processing** — construct the engine with
   `SCKCaptureEngine.Configuration(voiceProcessingEnabled: false)`.
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
