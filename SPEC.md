# MeetingKit v0 — Standalone macOS Menu Bar App

**Spec version:** 1.2 · August 2026
**Status:** Build target for Phase 0 (dogfood)
**Team:** 2 engineers · Fully independent installs · Local-only data
**Platform baseline:** macOS 14.0+ · Apple Silicon only (both dogfood machines are M-series)

**Changelog v1.1 → v1.2:** Validator redesigned: deterministic quote-based validation replaces "topically related" (normalization-tolerant string matching against text-only rendering; LLM-judge topicality deferred to a named Phase 1+ experiment). Canonical rendering block pinned (single formatter/parser, per-timestamp hours rule, round-trip test); `prompt_version` documented as covering prompt text **and** rendering format. Eval case export path added (History action + pinned self-contained JSON schema + weekly merge ritual). Title sanitization. Chunked fusion renders global session offsets (validator code path unchanged). Session clock pinned to `mach_continuous_time`; elapsed display derives from wall clock.

**Changelog v1.0 → v1.1:** Added Week-1 spike section (§7). TranscribeKit redesigned: shared model instance + serial per-channel queues; segment upsert semantics. Store renamed `Persistence`; GRDB decided; schema-first sequencing. Session titles from fusion output. Explicit pause/clock semantics. Timestamp-grounding rule for Decisions/Action items + validator. TCC relaunch flow. Min macOS 14, Apple Silicon only; Intel contingencies removed.

---

## 1. Purpose & Scope

A minimal, standalone macOS menu bar app that captures meeting audio, transcribes it on-device, lets the user jot timestamped fragments during the meeting, and produces polished notes afterward via frontier-LLM fusion.

v0 exists to **dogfood the core loop** and validate trust before any backend integration. It is deliberately local-only: no sync, no sharing, no accounts.

### In scope
- Manual start/stop audio capture (mic + system audio)
- Streaming on-device transcription with crash-safe persistence
- Timestamped scratchpad (fragment capture during meetings)
- Post-meeting fusion: transcript + fragments → structured notes (frontier model API)
- "Me vs. them" speaker separation via dual audio streams
- Local storage (GRDB/SQLite) with schema versioning
- Markdown export
- Minimal history window (list + detail view)
- Signed, notarized builds with Sparkle updates

### Explicitly out of scope (deferred)
| Feature | Deferred to |
|---|---|
| Meeting auto-detection / nudges | v0.2 |
| Calendar integration, attendee names | v0.2 |
| Templates library | Backend phase |
| Live progressive notes | Backend phase |
| Sharing, sync, multi-device | Backend phase (Phase 1+) |
| iOS companion | Later |
| Full diarization (beyond me/them) | Later |

---

## 2. Success Criteria (Phase 0 exit gate)

Do not proceed to backend integration until **all** of the following hold:

1. **20+ real meetings** captured across both users with zero data loss.
2. **Crash recovery verified**: force-quit mid-meeting → transcript up to the kill point survives, is viewable, and contains **no duplicate segments** (upsert semantics verified, §4.2).
3. **Device-switch survival**: AirPods disconnect/reconnect mid-call does not end or corrupt the session.
4. **Both-sides test**: both users record the same internal call; fused notes agree on all decisions and action items (wording may differ, facts may not).
5. **Timestamp validator green**: every Decision/Action item in fused notes cites a transcript timestamp that exists, **with a verbatim quote that matches the transcript within ±30 s of the citation** (§4.5).
6. **Trust bar (subjective)**: both users have stopped keeping backup manual notes in other tools.
7. **Friction logs maintained** by both users for the full dogfood period.

---

## 3. Architecture

### 3.1 Module layout (single Xcode project, local Swift Package)

```
MeetingKit.xcodeproj
├── App/                    # Menu bar app target (thin shell)
│   ├── MenuBarController   # Status item, states, menu
│   ├── ScratchpadPanel     # Floating NSPanel
│   ├── HistoryWindow       # Bare-bones list + detail
│   └── SetupWizard         # First-run permissions flow (survives TCC relaunch)
└── Packages/MeetingKitCore/
    ├── CaptureKit          # SCStream + AVAudioEngine → PCM buffers
    ├── TranscribeKit       # Transcriber protocol; WhisperKit impl (shared model, serial queues)
    ├── ScratchpadKit       # Timestamped fragment store
    ├── FusionKit           # FusionProvider protocol; frontier-model impl + prompt assembly
    ├── SessionKit          # Session lifecycle, crash recovery
    └── Persistence         # GRDB/SQLite, schema versioning, migrations, export
```

**Architectural rule (load-bearing for later phases):** all components communicate through the local store via events. Capture/transcription/scratchpad *write* to the store; fusion *reads* from it. Nothing calls anything else directly across module boundaries. In Phase 1+, `Persistence` grows a sync layer and fusion relocates server-side with no upstream changes.

### 3.2 Data flow

```
Mic (AVAudioEngine) ──┐
                      ├─→ CaptureKit ─→ TranscribeKit ─→ Persistence (upsert, ≤5s after finalization)
System audio ─────────┘                                     ↑
(ScreenCaptureKit)                    ScratchpadKit ────────┘ (fragments)
                                                            │
                              Session ends → FusionKit reads store
                                           → frontier API → notes (+ title) → Persistence
```

---

## 4. Component Specs

### 4.1 CaptureKit

**Responsibility:** Produce two synchronized PCM streams — `local` (mic) and `remote` (system audio) — with a shared session clock.

- **System audio:** `SCStream` with `SCStreamConfiguration.capturesAudio = true`, `excludesCurrentProcessAudio = true`. Capture the **main display** (not filtered windows — filtered audio capture has its own bug surface). There is no audio-only SCStream; video frames are unavoidable. Minimize waste: `minimumFrameInterval` = 1 fps, `width`/`height` = 2×2, `showsCursor` = false, discard all video frames on arrival.
- **Mic:** `AVAudioEngine` input node with voice processing (`setVoiceProcessingEnabled(true)`) for echo cancellation — **subject to the §7 spike outcome**. If voice processing destabilizes coexistence with SCStream on either machine, fall back to voice processing off and accept partial bleed (channel separation degrades but survives — levels differ enough to keep me/them useful).
- **Start order:** determined by the §7 spike (default hypothesis: SCStream first, then engine). Whatever the spike finds becomes a code comment with the macOS build numbers tested.
- **Format:** Downsample both streams to 16 kHz mono Float32 before handing to TranscribeKit.
- **Session clock (pinned):** `mach_continuous_time`-based, started at session begin. Every buffer is stamped with offset-from-session-start; wall-clock start time stored once on the session record. `mach_continuous_time` is chosen deliberately — it advances across sleep, matching §4.1's stated model ("clock keeps running, gaps are honest"). **Two clocks, two jobs:** the session clock stamps audio offsets; the menu-bar elapsed display and session durations derive from **wall clock**, never the session clock.
- **Pause/clock semantics (explicit):** the session clock **keeps running** through device switches and sleep. Offsets have honest gaps; `device_events` explains them. Session duration in History = wall-clock end − start. There is exactly one timeline; no inactive-time exclusion.
- **Device switching:** Subscribe to `AVAudioEngineConfigurationChange` + route-change notifications. On change: pause, rebuild engine graph, resume. Session must survive; log a `deviceChanged` event.
- **Failure modes:**
  - Screen Recording permission revoked mid-session → end system-audio stream gracefully, continue mic-only, surface a warning.
  - SCStream error/stall → one silent restart; on second failure, continue mic-only.

**Permissions & first-run flow:** Screen Recording (system audio) + Microphone. Screen Recording TCC **requires an app relaunch after granting**. SetupWizard flow: explain both permissions → trigger mic prompt → trigger Screen Recording prompt → instruct "quit and reopen" → on relaunch, a persisted `setupPhase` flag resumes the wizard where it left off. Never assume prompts alone complete setup.

### 4.2 TranscribeKit

**Responsibility:** Streaming-style speech-to-text for both channels, on-device.

- **Engine:** WhisperKit. Note: WhisperKit is **chunked batch transcription over rolling VAD windows**, not true streaming — the `Transcriber` protocol below is the seam that hides this.
- **Model:** `small.en` default (both machines are M-series; 3–5 s finalization is realistic). Model remains a build-time setting.
- **Shared model, serial queues (architecture decision):** **one** WhisperKit model instance, **two serial inference queues** (one per channel). Two model instances (~1 GB RAM, GPU contention) are explicitly rejected. Consequence: the busier channel (usually `remote`) lags the quieter one. Acceptable for v0 — nothing consumes the transcript live — but stamp each segment with `inferredAt` (inference completion time) separately from audio offsets, so Phase 2 live-notes work starts with a real latency distribution.
- **Interface:**

```swift
protocol Transcriber {
    func transcribe(stream: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptSegment>
}

struct TranscriptSegment {
    let id: UUID                  // assigned at FIRST hypothesis, stable across revisions
    let channel: Channel          // .local (me) | .remote (them)
    let text: String
    let startOffset: TimeInterval // session-clock relative
    let endOffset: TimeInterval
    let isFinal: Bool
    let inferredAt: Date
}
```

- **Upsert semantics (hard rule):** segments get a UUID at hypothesis creation; a revised hypothesis **replaces** the row on that ID — never appends. This is what makes the crash-recovery test meaningful: without it, the 5s-persistence kill-test passes while the recovered transcript is full of duplicates. The Phase 0 exit gate (§2.2) checks for this explicitly.
- **Chunking:** WhisperKit's built-in energy VAD. Target segment finalization within ~3–5 s of speech ending.
- **No temp audio on disk:** verify WhisperKit's configuration writes no temporary audio files (part of the §4.6 retention audit).
- Model download on first launch with progress UI.

### 4.3 ScratchpadKit

**Responsibility:** Capture user-typed fragments with timestamps during a session.

- A fragment = a burst of typing. Burst boundary: ≥3 s pause or explicit newline.
- Each fragment stores: `text`, `anchorOffset` (session clock at burst **start**), `createdAt`.
- **Lookback anchoring rule:** the fragment's *effective* transcript anchor is `anchorOffset − 20s` (constant for v0, tune during dogfood). Users type about what was just said; fusion must look backward from the timestamp, not at it.
- Fragments are editable during the session, immutable after fusion runs.

### 4.4 SessionKit

**Responsibility:** Session lifecycle and crash safety.

- **States:** `idle → recording → processing → complete` (+ `recovered` flag).
- **Start/Stop:** manual via menu. Stop finalizes pending segments → `processing` → fusion.
- **Crash recovery:** on launch, scan for sessions stuck in `recording`. Mark `recovered`, offer fusion on whatever persisted. **Persistence cadence: segments and fragments hit SQLite within 5 s of finalization — never memory-only.** Combined with upsert semantics (§4.2), recovery yields a clean, duplicate-free transcript.
- **Interruptions:** sleep/wake → pause/resume capture (clock keeps running, §4.1); display lock does not stop the session.

### 4.5 FusionKit

**Responsibility:** Turn (transcript + fragments) into structured notes + a session title.

- **Provider:** Frontier model via direct API (Claude Sonnet-class; decided). Per-user API key in Keychain, entered in Settings. Behind a `FusionProvider` protocol — relocates server-side in Phase 2 unchanged upstream. **Temperature 0–0.3** (grounding task, not creative; also keeps the both-sides test meaningful).

#### Canonical rendering (three-way contract)

The rendering format is a contract between **three** parties: the prompt assembler (writes it), the fusion model (reads it and cites into it), and the validator (parses both sides). Any drift produces validator failures that look like model hallucination but are actually format skew — the worst bug class here, because it poisons the eval set with false positives.

- **Timestamp format:** `[MM:SS]` for offsets < 1:00:00; `[H:MM:SS]` for offsets ≥ 1:00:00 (**per-timestamp rule** — a long meeting contains both forms). The parser accepts both forms unconditionally, anywhere.
- **Line template:** `[MM:SS] Me: text` / `[1:02:14] Them: text`.
- **User-note injection:** `[USER NOTE @ 14:32] pricing objection`, placed inline at the fragment's effective anchor (§4.3).
- **One formatter, one parser, same source file**, in FusionKit. A unit test asserts round-trip consistency (format → parse → identical offsets), covering both timestamp forms.
- **`prompt_version` covers prompt text AND rendering format** as one unit — the model's citation behavior is conditioned on both. Any change to either bumps the version. This is documented in the schema notes so nobody "refactors" the formatter without bumping.

#### Prompt assembly

- System prompt: role, output format, grounding rules ("only state what the transcript supports; fragments indicate what mattered to the user").
- Transcript rendered per the canonical rendering above, with channel labels (`Me:` / `Them:`).
- Fragments injected inline at their effective anchor positions, marked distinctly.

#### Output format (fixed for v0)

0. **Title:** one line, ≤8 words (becomes the session title in History — pre-fusion sessions display date/duration). Sanitized before storage/display: strip markdown, quotes, trailing punctuation; truncate at display width; fall back to date/duration if empty.
1. **Summary** (2–4 sentences)
2. **Key points** (grouped by topic)
3. **Decisions** — each item = **timestamp + verbatim transcript quote (5–15 words) + item text**
4. **Action items** (with owner if inferable) — each item = **timestamp + verbatim transcript quote (5–15 words) + item text**

#### Validator (deterministic, day one)

- **(a) Timestamp exists:** every cited timestamp exists in the transcript.
- **(b) Quote matches:** every quote appears in the transcript within ±30 s of its citation.
- **Matching is normalization-tolerant but judgment-free.** Normalize both sides: lowercase, strip punctuation, collapse whitespace — no semantics. Whisper output has inconsistent casing/punctuation, and the fusion model may "clean up" a quote when reproducing it; without normalization, false validator failures erode trust in the one tool that must never cry wolf.
- **Quotes may span segment boundaries; matching runs against the text-only rendering** (timestamp and channel-label tokens stripped). Otherwise a quote spanning two adjacent segments would fail because `[14:32] them:` sits between the quoted words. The text-only rendering is produced by the same canonical formatter — not a second implementation.
- Validator failures are surfaced in the UI and auto-saved to the eval set. No model calls, no API cost, per check.
- **Chunked long meetings:** chunks are rendered with **global session offsets from the start** — chunk-local timestamps never exist. Per-chunk citations validate against the global timeline with the same code path; the validator needs no remapping logic.
- **LLM-judge topicality (named Phase 1+ experiment, not built in v0):** its one legitimate future use is catching a technically-real quote attached to an unrelated item. Rare failure mode; the eval set will tell us if it isn't.

#### Operational rules

- **Zero-fragment mode:** fusion must produce useful notes with an empty scratchpad.
- **Long meetings:** single-shot up to practical context; beyond ~25k words, chunk by VAD gaps → per-chunk summaries → final compose (stopgap; full map-reduce is Phase 2).
- **Prompt versioning:** every note row records `prompt_version` (covering prompt + rendering format). Any change bumps it. Non-negotiable — this is what makes the eval set a regression suite.
- **Two-pass experiment (week 3+):** A/B a second, stricter pass that extracts only Action items, against the eval set once it has ~10 meetings. Action-item precision is the metric that gates Phase 4.
- **Failure:** fusion errors leave the session in `processing` with Retry. Raw transcript always viewable.

#### Eval set

- Every meeting where fusion was wrong (hallucination, misattribution, missed decision, validator failure) is saved — transcript + fragments + bad output + corrected output.
- **Collection path (v0):** History window action **"Export eval case"** (enabled on any session with a fusion output; prompts for optional corrected output) → one self-contained JSON file → dropped into the shared `evals/` folder → **merged during the weekly review** (§9). Manual, boring, uses the one sharing mechanism v0 permits. A hidden benefit: both of you *look at* each case as it enters the corpus — the review discipline that makes an eval set good rather than large.
- **Eval case JSON schema (pinned):** self-contained and versioned so cases survive the originating database being wiped or migrated; `machine_id` so "does this failure mode cluster on one person's setup?" is answerable in Phase 2.

```json
{
  "schema_version": 1,
  "prompt_version": "…",
  "model": "…",
  "session_id": "UUID",
  "session_started_at": "ISO-8601",
  "title": "…",
  "transcript": [ {"channel": "me|them", "text": "…", "start_offset": 0.0, "end_offset": 0.0} ],
  "fragments": [ {"text": "…", "anchor_offset": 0.0} ],
  "output": "markdown",
  "corrected_output": "markdown | null",
  "validator_result": "…",
  "exported_at": "ISO-8601",
  "machine_id": "stable per-install ID"
}
```

### 4.6 Persistence

- **Engine:** **GRDB** (decided). Explicit schema control, background writers, and a clean migration path — all needed for Phase 1. SwiftData rejected for this workload.
- **Sequencing (cross-team contract):** Engineer B delivers `Persistence` + schema v1 + GRDB setup **in the first 2 days**, before ScratchpadKit/FusionKit. The schema is the interface between the two engineers; Engineer A is blocked without it. **After day 2, every schema change requires a migration file** — even in dogfood. This habit is what makes the Phase 1 history-upload migration painless.
- **Schema v1:**

```sql
meta        (schema_version INTEGER)          -- REQUIRED from day one
sessions    (id, started_at, ended_at, state, recovered, title, device_events JSON)
segments    (id UUID PRIMARY KEY,             -- stable across hypothesis revisions; UPSERT on id
             session_id, channel, text,
             start_offset, end_offset, is_final, inferred_at, created_at)
fragments   (id, session_id, text, anchor_offset, created_at)
notes       (id, session_id, markdown, model, prompt_version, is_canonical, created_at)
```

- **Multiple notes per session** are intentional: keep all fusion attempts, mark the latest `is_canonical`. Makes the eval-set workflow (bad output vs. corrected) free.
- **Retention policy (v0):** raw audio is **discarded** — never written to disk by our code, and the audit includes verifying WhisperKit writes no temp audio files. Transcript-only retention. (A product/legal stance, not a shortcut; revisit before any enterprise deployment.)
- **Export:** any session → single markdown file (notes + collapsible transcript). The only sharing mechanism in v0, by design.

---

## 5. UI Spec (deliberately minimal)

### Menu bar item
- States: idle (mono icon) · recording (red dot + elapsed time) · processing (spinner). Elapsed time derives from wall clock (§4.1).
- Menu: `Start/Stop Meeting` · `Open Scratchpad` · `History` · `Settings` · `Quit`.
- **Recording indicator is always visible while capturing** — non-negotiable (consent/transparency posture).

### Scratchpad panel
- Floating `NSPanel`, `nonactivatingPanel` style — stays above other windows, doesn't steal focus from the meeting app.
- Plain text area + elapsed-time header + Stop button.
- **Global hotkey** (default `⌥⌘N`) via Carbon `RegisterEventHotKey` — no Accessibility permission needed. Do **not** use NSEvent global monitors (permission-hungry).
- No formatting, no toolbar. Fragments are ephemeral input, not documents.

### History window
- Left: session list (fusion-generated title — or date/duration pre-fusion — plus date, duration, state). Right: rendered notes with toggle to raw transcript; validator warnings shown inline.
- Actions: Export markdown · Retry fusion · Delete · **Export eval case** (enabled on any session with a fusion output; prompts for optional corrected output; §4.5).
- **Do not invest here.** Scheduled for deletion in Phase 3 when the webapp becomes the read surface.

### Settings
- API key (Keychain) · Whisper model picker · lookback window (advanced) · launch at login.

### Setup wizard
- Explains permissions → mic prompt → Screen Recording prompt → "quit and reopen" instruction → resumes via `setupPhase` flag on relaunch → model download → API key entry → done.

---

## 6. Distribution & Updates

- Developer ID signing + notarization from the first shared build. No unsigned .app handoffs.
- **Sparkle 2** for updates; appcast on static hosting (GitHub releases fine for v0).
- Hardened runtime; entitlement `com.apple.security.device.audio-input`; Screen Recording via TCC prompt (no entitlement).
- `Info.plist`: `NSMicrophoneUsageDescription` + screen-capture purpose string.
- Direct download only. Mac App Store explicitly ruled out (sandbox incompatible with this capture pattern).
- **Deployment target: macOS 14.0, Apple Silicon only** (`arm64`; no universal binary needed for dogfood).

---

## 7. Week-1 Spikes (before "real" code)

Three risks get dedicated spike branches in days 1–3. Spike results are written up as code comments + a short note in the repo, with macOS build numbers tested.

### Spike 1: SCStream + AVAudioEngine coexistence (Engineer A) — **the #1 platform risk**
Known interference on macOS 14.x: activating SCK audio capture while an AVAudioEngine input tap runs can silently kill the mic stream (or vice versa); voice processing worsens it in some builds.
- **Test matrix (8 runs, both machines):** {SCStream first, engine first} × {voice processing on, off} × {machine 1, machine 2}.
- Success: both streams stable for 10+ minutes, device-switch survival, across both machines' macOS point releases.
- Outcomes feed §4.1 directly: start order + voice-processing decision become documented constants.
- Fallback ladder: fixed start order → voice processing off (accept bleed) → same-engine mic tap restructure.

### Spike 2: WhisperKit shared-model throughput (Engineer A)
- One `small.en` instance, two serial queues, simulated two-channel load (play a recorded call).
- Measure: finalization latency per channel, RAM, GPU contention, lag of busier channel.
- Success: p95 finalization ≤ 5 s on both machines. (Both are M-series; if this fails, something is misconfigured — investigate before downgrading the model.)

### Spike 3: Schema v1 + GRDB + upsert (Engineer B)
- Deliver `Persistence` with schema v1, migration scaffolding, and segment upsert.
- Prove: kill -9 during simulated segment stream → reopen → transcript intact, duplicate-free.
- Done by day 2; unblocks Engineer A's integration.

---

## 8. Work Split & Milestones

### Ownership
- **Engineer A — Platform:** CaptureKit, TranscribeKit, SessionKit, signing/notarization/Sparkle. Spikes 1–2.
- **Engineer B — Product:** Persistence (first), ScratchpadKit, FusionKit (prompt iteration), UI, eval set + validator. Spike 3.

### Milestones
| Week | Milestone | Definition of done |
|---|---|---|
| 1 | **Spikes resolved** | §7 outcomes documented; start order, voice-processing, and throughput decisions locked |
| 1 | **Schema live** | Persistence + schema v1 + upsert proven (day 2) |
| 2 | **Transcript persisted** | Streaming transcription → SQLite; kill-test passes duplicate-free |
| 2 | **Scratchpad live** | Panel + hotkey + fragment anchoring |
| 3 | **Fusion loop closed** | End-to-end: meeting → titled notes; validator running; first real dogfood meeting |
| 3 | **Signed builds** | Notarized .app + Sparkle update tested between both machines |
| 4 | **Hardening** | Device-switch, sleep/wake, permission-revocation, TCC-relaunch tests pass; both users on daily driver |
| 4+ | **Dogfood** | Friction logs running; drive toward Phase 0 exit gate (§2) |

---

## 9. Dogfood Protocol

- **Friction log** (per person, shared doc): `date · meeting · what broke or annoyed me`. Weekly joint review.
- **Weekly review agenda:** friction logs → **merge exported eval cases into the shared `evals/` folder** (§4.5) → review validator failure patterns.
- Track specifically:
  1. Forgot-to-record incidents (→ prioritizes auto-detection for v0.2)
  2. Scratchpad usage rate (fragments per meeting; zero-fragment frequency)
  3. Notes reopened later? Which sections? (→ informs webapp read surface)
  4. Fusion errors + validator failures → straight into the eval set
- **Diverge setups deliberately:** different headphones, different primary meeting apps between the two of you.
- **Week 3 both-sides test:** record the same internal call from both machines; diff the fused notes.

---

## 10. Risks

| Risk | Mitigation |
|---|---|
| SCStream/AVAudioEngine interference (macOS 14.x) | Spike 1 matrix; fallback ladder documented; mic-only degradation path |
| Echo/bleed if voice processing must be disabled | Accept partial bleed; channel separation survives on level differences |
| WhisperKit revision duplicates corrupting recovery | Stable segment UUIDs + upsert (hard rule); exit gate checks it |
| SCStream instability across macOS point releases | Silent-restart logic; spike notes record tested build numbers |
| API key in client | Accepted for v0 (own keys, own machines); `FusionProvider` seam ensures clean Phase 2 removal |
| Fusion hallucination | Low temperature; timestamp + verbatim-quote grounding; deterministic validator; eval set |
| Format skew between formatter/parser/validator | Single-source formatter + parser in one file; round-trip unit test; `prompt_version` covers format |
| n=2 blind spots | Named and accepted; hand builds to 2–3 outsiders before Phase 1 |
| Legal posture on recording | Always-visible indicator; transcript-only retention (audited, incl. WhisperKit temp files); revisit before external users |

---

## 11. What v0 Deliberately Refuses To Be

No accounts. No cloud storage. No sharing. No meeting detection. No templates. No beautiful library. The urge to add any of these during dogfood is *signal to be logged*, not scope to be added. v0 succeeds when two people trust it with every meeting — everything else is the backend's job.

**Spec hygiene rule (standing):** a feature isn't specced until its plumbing is — how it runs deterministically, how formats stay synced, how data actually moves. Every v1.1 regression traced to adding a capability without its operational path; watch for this pattern in every future spec round.
