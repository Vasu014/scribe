# Scribe Build-Out Task List

Working task list for the v0 build (SPEC.md v1.3 is the contract; `design/` is the UI
reference). Lead (this session) reviews every diff, runs tests, and commits — subagents
implement and report, they do not commit.

Legend: □ todo · ◐ in flight · ✔ done · — blocked/not started

## Wave 1 — core modules (sequential dispatch, disjoint files)

| # | Task | Module | Status | Summary |
|---|------|--------|--------|---------|
| T1 | Fusion service + provider + eval-case builder | FusionKit | □ | `AnthropicFusionProvider` (URLStream/Keychain key), `FusionService` orchestration (store→assemble→complete→title→validate→store note+title) behind protocol; system prompt v1 text; `EvalCase` Codable builder per SPEC §4.5 JSON. Mock-provider tests. |
| T2 | Session coordinator | SessionKit | □ | Start/stop lifecycle, wiring capture→transcriber→store with ≤5s persistence, crash-recovery scan on init (mark `recovered`), stop→`processing`→fusion→`complete`, failure→`processing`+error for Retry, device/interruption event logging. Tests with StubCaptureEngine + mock transcriber/fusion. |
| T3 | WhisperKit transcriber | TranscribeKit | □ | Add WhisperKit dep; `WhisperKitTranscriber`: shared model instance + two serial per-channel queues, VAD windowing, stable segment UUIDs across hypothesis revisions, 16kHz mono input, no-temp-audio config; model download manager w/ progress. Unit tests with a fake batch engine (id stability, queue serialization); no model-download in CI. |
| T4 | Real capture engine | CaptureKit | □ | `SCKCaptureEngine`: SCStream (main display, 2×2 @1fps, audio, excludesCurrentProcessAudio) + AVAudioEngine mic w/ voice-processing toggle + start-order constant (spike pending; default SCStream first), `mach_continuous_time` session clock, 16kHz mono downsample (AVAudioConverter), device-change rebuild + `deviceChanged` event, permission-revoked & double-failure → mic-only degradation. Compiles headless; manual validation checklist in PR notes. |

## Wave 2 — app surfaces (sequential, all in App/)

| # | Task | Depends | Status | Summary |
|---|------|---------|--------|---------|
| T5 | Menu bar shell + Settings + hotkey | T2 | □ | `MenuBarController` (5 derived states incl. done-transient 4s + persistent failed, wall-clock elapsed, dot pulse); `SettingsWindow` (Keychain API key masked, model picker, lookback, SMAppService login); Carbon `RegisterEventHotKey` ⌥⌘N. Follows design/ + macos-patterns skill. |
| T6 | Scratchpad panel | T2, T5 | □ | Floating `.nonactivatingPanel` HUD, header (dot+elapsed+hint+Stop / no-meeting state), text body → `FragmentComposer` wiring, saved tick on persist, Esc dismiss, summon animation w/ Reduce Motion fallback. |
| T7 | History window + exporters | T1, T2 | □ | Sidebar (title/meta/date/recovered tag, fused/fusing/failed) + detail (Notes/Transcript toggle, rendered markdown, inline validator cards, static action checkboxes); actions: export markdown (notes + `<details>` transcript), retry fusion, export eval case (optional corrected output), delete. Empty state per design 2d. |
| T8 | Setup wizard | T5, T3 | □ | `setupPhase`-persisted flow: permission explain → mic prompt → screen-recording prompt → relaunch instruction → model download progress → API key entry → done. |

## Wave 3 — hardening & release

| # | Task | Depends | Status | Summary |
|---|------|---------|--------|---------|
| T9 | Release engineering | all | □ | Sparkle 2 SPM + appcast template, notarytool script (env-gated; team ID placeholder), hardened-runtime check, root README (build/test/layout). |
| T10 | Dogfood hardening | T4 | — | Spike-1 matrix runs (hardware), device-switch/sleep/permission-revocation passes. Manual; post-dogfood. |

## Notes for every task
- SPEC.md section citations in code comments where behavior is specced.
- `swift test` green in Packages/MeetingKitCore before reporting done; App work: `make build` green.
- Do not commit — leave the tree dirty, report files changed + test output. Lead reviews, commits.
