# Scribe Build-Out Task List

Working task list for the v0 build (SPEC.md v1.3 is the contract; `design/` is the UI
reference). Lead (this session) reviews every diff, runs tests, and commits — subagents
implement and report, they do not commit.

Legend: □ todo · ◐ in flight · ✔ done · — blocked/not started

## Wave 1 — core modules (sequential dispatch, disjoint files)

| # | Task | Module | Status | Summary |
|---|------|--------|--------|---------|
| T1 | Fusion service + provider + eval-case builder | FusionKit | ✔ | `AnthropicFusionProvider` (URLStream/Keychain key), `FusionService` orchestration (store→assemble→complete→title→validate→store note+title) behind protocol; system prompt v1 text; `EvalCase` Codable builder per SPEC §4.5 JSON. Mock-provider tests. |
| T2 | Session coordinator | SessionKit | ✔ | Start/stop lifecycle, wiring capture→transcriber→store with ≤5s persistence, crash-recovery scan on init (mark `recovered`), stop→`processing`→fusion→`complete`, failure→`processing`+error for Retry, device/interruption event logging. Tests with StubCaptureEngine + mock transcriber/fusion. |
| T3 | WhisperKit transcriber | TranscribeKit | ✔ | Add WhisperKit dep; `WhisperKitTranscriber`: shared model instance + two serial per-channel queues, VAD windowing, stable segment UUIDs across hypothesis revisions, 16kHz mono input, no-temp-audio config; model download manager w/ progress. Unit tests with a fake batch engine (id stability, queue serialization); no model-download in CI. |
| T4 | Real capture engine | CaptureKit | ✔ | `SCKCaptureEngine`: SCStream (main display, 2×2 @1fps, audio, excludesCurrentProcessAudio) + AVAudioEngine mic w/ voice-processing toggle + start-order constant (spike pending; default SCStream first), `mach_continuous_time` session clock, 16kHz mono downsample (AVAudioConverter), device-change rebuild + `deviceChanged` event, permission-revoked & double-failure → mic-only degradation. Compiles headless; manual validation checklist in PR notes. |

## Wave 2 — app surfaces (sequential, all in App/)

| # | Task | Depends | Status | Summary |
|---|------|---------|--------|---------|
| T5 | Menu bar shell + Settings + hotkey | T2 | ✔ | `MenuBarController` (5 derived states incl. done-transient 4s + persistent failed, wall-clock elapsed, dot pulse); `SettingsWindow` (Keychain API key masked, model picker, lookback, SMAppService login); Carbon `RegisterEventHotKey` ⌥⌘N. Follows design/ + macos-patterns skill. |
| T6 | Scratchpad panel | T2, T5 | ✔ | Floating `.nonactivatingPanel` HUD, header (dot+elapsed+hint+Stop / no-meeting state), text body → `FragmentComposer` wiring, saved tick on persist, Esc dismiss, summon animation w/ Reduce Motion fallback. |
| T7 | History window + exporters | T1, T2 | ✔ | Sidebar (title/meta/date/recovered tag, fused/fusing/failed) + detail (Notes/Transcript toggle, rendered markdown, inline validator cards, static action checkboxes); actions: export markdown (notes + `<details>` transcript), retry fusion, export eval case (optional corrected output), delete. Empty state per design 2d. |
| T8 | Setup wizard | T5, T3 | ✔ | `setupPhase`-persisted flow: permission explain → mic prompt → screen-recording prompt → relaunch instruction → model download progress → API key entry → done. |

## Wave 3 — hardening & release

| # | Task | Depends | Status | Summary |
|---|------|---------|--------|---------|
| T9 | Release engineering | all | ✔ | Sparkle 2 SPM + appcast template, notarytool script (env-gated; team ID placeholder), hardened-runtime check, root README (build/test/layout). |
| T10 | Dogfood hardening | T4 | ◐ | Harness landed (S1): `Tools/SpikeHarness` + `scripts/spike1-run.sh`; **smoke matrix 4/4 OK on macOS 26.3** (90 s runs, both channels continuous, no degradation). Remaining: full 600 s matrix on both machines (+ AirPods pass), pin outcome in `SCKCaptureEngine`, sleep/permission-revocation passes, then dogfood toward the Phase 0 exit gate (SPEC §2). |

## Wave 4 — UI polish & interaction hardening (2026-08-19 dogfood round)

Triggered by the first real dogfood: the UI had been verified from screenshots, not by driving it,
so the interaction layer shipped broken. `.agents/ux-accessibility-review.md` (27 findings: 8
blockers, 10 major, 9 minor) and `.agents/design-spec.md` (919-line acceptance checklist extracted
from the canvas, incl. new §3a/§3b/§4a) are the work lists.

| # | Task | Status | Summary |
|---|------|--------|---------|
| T11 | Visual polish vs design | ✔ | Screenshot harness (`App/UIGallery.swift` + `scripts/ui-gallery.sh`, 10 scenes). Settings grouped cards, History validator card + markdown paragraph joining, scratchpad 312 pt + stretchable corner mask, wizard alignment/footer, menu-bar glyph geometry. Full dark-mode pass (hardcoded `black.withAlphaComponent` → dynamic system colors). |
| T12 | Stop / frozen elapsed | ✔ | Root cause: `LazyWhisperKitTranscriber` never called `continuation.finish()` on the model-LOADED path, so the drain awaited forever and `stop()` hung before writing `processing`. Masked until `path(percentEncoded:)` made WhisperKit actually load. Drain now bounded (`transcriptDrainTimeout`), state written before draining, regression test added. |
| T13 | Keyboard & reachability | ✔ | Main menu (App/Edit/Window — ⌘W ⌘Q ⌘, and **⌘V**, which had made API-key paste impossible); quit-while-recording confirm; panel key focus + `acceptsFirstMouse`; panel-scoped Esc hotkey; single-instance guard; History keyboard nav (⌘1/⌘2, ⌘⌫, ⌘E, ⌘R, ⇧⌘E, initial responder, focus rings); wizard Esc; ⌘. = Stop. |
| T14 | Accessibility | ✔ | Per-state VoiceOver labels on the status item (recording state was inaudible — the consent claim did not hold for blind users); labels across panel/History/Settings/wizard; contrast lifted to WCAG AA (HUD muted text → white 60%); Increase Contrast + live Reduce Motion observers. Text size accepted as a documented v0 limitation (AppKit has no Dynamic Type). |
| T15 | Fullscreen recording chip (§4a) | ◐ | Design 4a: non-activating top-right chip, shown only while capturing AND the status item is off-screen; pulsing dot + elapsed, Stop on hover, drag along top edge, 4 s → 60% idle fade. Closes the §3b consent invariant that broke in fullscreen. Includes approved deviations D1/D2 (see design-spec "Approved deviations"). |
| T16 | Meeting auto-detection | □ | ROADMAP (owner: "part of roadmap later"). Calendar-triggered pre-meeting prompt + microphone-in-use detection for unscheduled calls, so the user never clicks Start blind. Removes the failure mode D2 currently compensates for. |
| T17 | Correctness audit fixes | ◐ | From `.agents/audit-{app-layer,capture-core,data-fusion}.md` (49 findings: 3 critical, 20 major). Landed: session-scoped pipeline (a stalled drain no longer zeroes the NEXT session's segments), `drivesDisplay` resolved at apply time in BOTH `stop()` and `retryFusion`, fusion in-flight guard, validator rebuilt (scanned citations + required-citation check + per-channel matching), `claude-sonnet-5` + temperature omitted, bad-key vs outage distinguishable, deleted scratchpad text no longer reaches fusion, History fusing-timer lifecycle, store-failure alert replacing the silent in-memory fallback, capture-degradation banner, Esc global grab removed. |

### Follow-ups surfaced by T17 (API gaps agents correctly refused to fake)

| # | Task | Status | Why it matters |
|---|------|--------|----------------|
| T18 | `CaptureEngine.pause()`/`resume()` — clock-preserving | □ | SPEC §4.4 requires sleep/wake to pause and resume capture. Today only device events are logged and the mic can stay dead for the rest of a meeting after wake. Calling `start()` again is NOT a resume: `SCKCaptureEngine.start()` re-creates the `MachSessionClock`, so every later buffer would be re-stamped from zero and every fragment anchor would be wrong. Needs a real pause/resume (or `rebuildGraph()`) plus a per-channel liveness signal, so the app-side `CaptureLivenessMonitor` decorator can be retired. |
| T19 | `CoordinatorEvent.captureDegraded` + surface notice API | □ | System-audio degradation is currently surfaced by an app-owned floating banner because `MenuBarController` / `ScratchpadPanelController` / `RecordingChipController` expose no notice entry point (`showWarning(title:detail:)` or a `notice` property → status-item ⚠ + menu row + panel header line), and SessionKit has no degradation event. Without the event, History and `device_events` cannot record that a meeting captured mic-only. |
| T20 | `MeetingStore.deleteFragment` | □ | Discarding a pending scratchpad burst blanks the row but cannot remove it, so an empty tombstone survives and still counts toward History's "fused from N fragments". Needs a real delete wired through `onDiscardPending`. |
| T22 | Store-failure alert wording for `schemaTooNew` | □ | The alert offers "Move Database Aside and Retry" for a store written by a NEWER Scribe, where the right action is "update Scribe". Nothing is lost (it renames, never deletes), but the button is misleading for that one case. Found by the migration regression suite. |
| T21 | Extend the suite to the defect classes it missed | ✔ | 82 tests passed while the app's core action was dead. Audits found findings #1–#6 (capture) entirely uncovered. Wanted: session-boundary races, abnormal-termination paths, stream-continuation completion on every branch, and the silent-degradation paths. **Done**: 234 package + 84 App = 318 tests (from 82). New `ScribeAppTests` target — App/ had zero tests and held the worst bugs. Suites verified to FAIL against reconstructed pre-fix code. |

### Verification standard (changed this round)
Screenshots are NOT verification for interaction. Every fix must be demonstrated by driving the real
app — synthetic events through a live AppKit event pump, in-process AX-tree readback, or store
assertions. Where the environment blocks it (e.g. a locked screen prevents real hover/click/key-window
behavior), that must be reported explicitly as "unverified — requires unlocked screen" rather than
implied to be tested.

## Notes for every task
- SPEC.md section citations in code comments where behavior is specced.
- `swift test` green in Packages/MeetingKitCore before reporting done; App work: `make build` green.
- Do not commit — leave the tree dirty, report files changed + test output. Lead reviews, commits.
