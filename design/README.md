# Handoff: Menu Bar Meeting Notes — macOS App UI

## Overview
UI design for a minimal macOS menu bar app that records meetings, lets the user jot ephemeral plain-text fragments in a floating scratchpad, and fuses fragments + transcript into markdown notes. Four surfaces: menu bar item, scratchpad panel, history window, settings. Plus empty states and a motion/interaction spec.

## About the Design Files
`Menu Bar App Designs.dc.html` is a **design reference created in HTML** — a spec sheet showing intended look and behavior, not production code. Recreate these designs natively in **Swift/AppKit (or SwiftUI where noted)** using system components wherever one exists (NSMenu, NSStatusItem, NSPanel, NSVisualEffectView, standard Settings controls). The HTML approximates system materials; on macOS, use the real ones.

## Fidelity
**High-fidelity.** Colors, type sizes, spacing, and copy are final intent — but always prefer the native system equivalent (system accent color, `NSColor.systemRed`, SF Pro via system font, `.hudWindow`/vibrancy materials) over the raw hex values, which exist only to simulate those materials in HTML.

## Screens / Views

### 1. Menu bar item (`NSStatusItem`) — design 1a, sequence 2c
Three states; the recording indicator must be visible whenever capturing (consent posture — non-negotiable).
- **Idle**: monochrome template-image waveform glyph (4 rounded bars, 15×13 pt).
- **Recording**: capsule (radius 5, `white 14%` fill in dark menu bar) containing a 7 pt red dot (`systemRed`, 1.6 s opacity pulse 100%→35%) + elapsed time, SF Mono 11.5 pt medium, tabular numerals (`24:16`).
- **Processing**: 13 pt indeterminate spinner (ring, 1.5 pt stroke, 0.9 s rotation) — use `NSProgressIndicator` small spinner.
- **Done (transient)**: green check in circle (`systemGreen` 12 pt) + "Notes ready" text; pops in with a 400 ms spring (overshoot ~1.12), holds 4 s, reverts to idle glyph. Clicking it opens the session in History.
- **Failure**: ⚠ glyph persists until the menu is opened; menu gains "Retry Fusion".

**Menu** (standard NSMenu, 13 pt system font, shortcuts right-aligned):
1. Start Meeting / Stop Meeting (shows elapsed time right-aligned while recording)
2. Open Scratchpad — ⌥⌘N
3. ——
4. History…
5. Settings… — ⌘,
6. ——
7. Quit — ⌘Q

### 2. Scratchpad panel — designs 1b (dark HUD, primary), 1c (light alt), 2a (states), 2e (saved tick)
Floating `NSPanel`, `.nonactivatingPanel` — floats above other windows, never steals key focus from the meeting app. Global hotkey ⌥⌘N (default, user-remappable later).
- **Size**: ~300–312 pt wide, content min-height ~150 pt; corner radius 12; HUD material (dark vibrancy ≈ `rgba(30,30,33,.9)` + 40 px blur), 0.5 pt border `white 14%`, shadow `0 18 48 black 40%`.
- **Header** (padding 10/12, hairline bottom border `white 10%`): red dot (7 pt, pulsing) + elapsed SF Mono 12 pt medium tabular `white 90%` · spacer · hotkey hint `⌥⌘N` 11 pt `white 35%` · **Stop** button: 12 pt medium, text `#FF6961` on `systemRed 16%` fill, radius 6, padding 3×10; hover fill 26%.
- **Body**: plain `NSTextView`, 13 pt system font, line-height 1.55, text `white 85%`; no formatting, no toolbar. Caret uses accent color.
- **Empty state** (2a): placeholder at 32% white: "Jot a fragment — plain text, saved as you type".
- **No-meeting state** (2a): header dot goes `white 25%` (static), label "No meeting" `white 50%`, Stop replaced by **Start Meeting** (white text on `#0A82FF`, hover `#2B93FF`); body hint: "Fragments typed here are discarded unless a meeting is recording."
- **Saved tick** (2e): pending-row pattern — the in-progress fragment persists as a mutable row on ~1 s debounce; a burst boundary (≥3 s pause / newline) freezes it. "Saved" 11 pt `white 45%` shows on persist, fades out after 2 s. No spinner.
- Light variant (1c) exists if HUD reads too heavy: `rgba(248,248,247,.92)` material, hairline separators `black 8%`, bordered gray Stop button.

### 3. History window — designs 1d, 2d (empty)
Standard titled window ~760×470. **Do not invest** — scheduled for deletion in Phase 3.
- **Sidebar** (236 pt, source-list material ≈ `#F2F1EF`, hairline right border): session rows radius 6, padding 7×10; selected fill `black 7%`. Row: title 13 pt medium `#1D1D1F` (truncating) + right-aligned meta 11 pt `black 45%` (duration `42 min`, or spinner + "fusing", or "failed" in `#E0483E`); crash-recovered sessions carry a small "recovered" tag capsule (9 pt, `systemYellow 22%` fill, `#8A6A00` text); second line date 11 pt `black 45%`.
- **Detail toolbar** (padding 12×16, hairline bottom): segmented control **Notes | Transcript** (12 pt; selected segment white pill with shadow) · spacer · bordered buttons **Export**, **Retry Fusion**, **Export Eval Case**, **Delete** (12 pt, radius 6, padding 3×10, 0.5 pt border `black 14%`; Delete text `#E0483E`).
- **Notes pane** (padding 20/24): title 17 pt semibold; meta line 11.5 pt `black 45%` ("Today, 9:00–9:42 AM · fused from 3 fragments"); section labels 12 pt semibold uppercase `black 50%` tracking .05em ("SUMMARY", "ACTION ITEMS"); body 13 pt/1.55 `#333`; action items as checkbox rows (13 pt boxes, radius 4, 1.5 pt border `black 25%`) — **static glyphs, not interactive**: v0 stores no action-item done-ness, and this surface must not grow into a todo widget. **Inline validator warnings** render in the notes flow: `systemYellow 12%` fill card, radius 7, 0.5 pt border, ⚠ glyph + 12 pt text, e.g. `Validator: "by Thursday" has no matching span in the transcript — verify before sending.` This is the hallucination-audit surface. Rendered markdown; toggle to raw transcript.
- **Empty state** (2d): centered — gray waveform glyph, "No sessions yet" 14 pt semibold `black 65%`, caption 12 pt `black 40%` "Start a meeting from the menu bar. Notes land here when fusion finishes.", bordered **Start Meeting** button.

### 4. Settings window — design 1e
Single pane, ~520 pt wide, System Settings grouped-row style: window bg `#F5F4F2`, groups are white cards radius 9, 0.5 pt border `black 10%`, rows padded 11 pt vertically with hairline separators inside a group. Labels 13 pt; captions 11 pt `black 45%`.
1. **Anthropic API Key** — caption "Stored in the macOS Keychain". Display masked (`••••••••••7f2a`, monospace); edit-in-place secure field. Store in Keychain, never plist.
2. **Whisper Model** — popup button. Default **Multilingual — Large** (`large-v3-v20240930_turbo`, ~1.64 GB; flag as a large download). Smaller and specialized options remain available. User setting, not build-time.
3. **Lookback Window** — caption "Advanced — how far back fusion anchors a fragment in the transcript"; popup (`20 seconds`, the v0 default). Fusion-time transcript-anchoring only — raw audio is never retained.
4. **Launch at Login** — standard switch (`systemGreen` on).

## Interactions & Behavior
- **Panel summon** (⌥⌘N): 180 ms ease-out, opacity 0→1 + scale .96→1 (origin top-center); dismiss 140 ms. Respect Reduce Motion → fade only.
- **Esc** dismisses the panel; recording continues (dot stays in menu bar).
- **Rec dot pulse**: 1.6 s ease-in-out opacity cycle; never hidden while capturing, including when the panel is closed.
- **Stop flow**: stop → spinner (fusing, ~20 s typical) → "Notes ready" transient (4 s) or persistent ⚠ on failure.
- Menu-item hover/selection: standard NSMenu behavior (accent-colored highlight).
- Fragment persistence: mutable pending row updated on ~1 s debounce; burst boundary (≥3 s pause / newline) freezes it into a committed fragment. The Saved tick is the only feedback and fires on actual persist.

## State Management
- App state machine: `idle → recording → processing → (done | failed)`; `done` auto-returns to `idle` after 4 s.
- Recording: elapsed timer (1 s tick), fragment buffer (append-only, timestamped).
- History: session list `{title, date, duration, state: fused|fusing|failed, recovered: bool}`; per-session notes markdown + raw transcript.
- Settings: apiKey (Keychain), whisperModel, lookbackSeconds, launchAtLogin.

## Design Tokens
Prefer system equivalents; hex values are the HTML simulation.
- Accent/blue `#0A82FF` (system accent) · Red `#FF453A` dark / `#FF3B30` light (`systemRed`) · Green `#34C759`/`#30D158` · Failure text `#E0483E`
- Dark HUD `rgba(30,30,33,.9)` + blur 40 · menu material `rgba(40,40,44,.78)` + blur 30 · light window `#F5F4F2` / sidebar `#F2F1EF`
- Text: SF Pro (system) 13 pt body, 11–12 pt meta, 17 pt title; SF Mono for elapsed time, tabular numerals everywhere numbers tick.
- Radii: panel/window 11–12 · buttons/rows 6 · cards 9 · menu-item highlight 5. Hairlines 0.5 pt.

## Assets
None — all glyphs are simple shapes (waveform bars, dot, ring spinner, check). Use SF Symbols equivalents: `waveform`, `record.circle`, `checkmark.circle.fill`, `exclamationmark.triangle`.

## Files
- `Menu Bar App Designs.dc.html` — open in a browser. Turn 1 (bottom section): 1a menu bar, 1b/1c scratchpad, 1d history, 1e settings. Turn 2 (top): 2a empty states, 2b summon animation (live), 2c stop→ready sequence, 2d history empty, 2e saved tick + motion spec.
