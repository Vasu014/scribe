# Design Spec — extracted from `design/Menu Bar App Designs.dc.html`

Acceptance checklist. Every value below is literally encoded in the design HTML (or, where marked
`[README]`, in `design/README.md`). Copy strings are exact and appear in backticks.

Conventions used in the tables:
- `px` values in the HTML are `pt` in AppKit (1:1 for this spec).
- CSS `font:<weight> <size>/<line-height> <family>` is split into separate rows only where it matters.
- `-apple-system` = SF Pro (system font, `NSFont.systemFont`); `ui-monospace,'SF Mono',Menlo` = SF Mono
  (`NSFont.monospacedSystemFont`).
- Surfaces that simulate OS-owned chrome (desktop wallpaper, the macOS menu bar strip, the system clock,
  traffic-light buttons) are marked as such — do not draw them.

---

## Shared keyframes (stylesheet `<style>` block)

| element | property | design value | note |
|---|---|---|---|
| `@keyframes spin` | transform | `to { transform: rotate(360deg) }` | indeterminate spinner rotation |
| `@keyframes recpulse` | opacity | `0%,100% { opacity: 1 }` · `50% { opacity: .35 }` | record-dot pulse, 100%→35%→100% |
| `@keyframes caret` | opacity | `0%,45% { opacity: 1 }` · `50%,100% { opacity: 0 }` | text caret blink |
| `@keyframes summon` | opacity + transform | `0%,4% { opacity:0; scale(.96) translateY(-5px) }` · `10%,72% { opacity:1; scale(1) translateY(0) }` · `80%,100% { opacity:0; scale(.98) translateY(-3px) }` | demo-loop encoding of the summon/dismiss transition |
| `@keyframes checkpop` | opacity + transform | `0% { opacity:0; scale(.6) }` · `60% { opacity:1; scale(1.12) }` · `100% { opacity:1; scale(1) }` | "Notes ready" spring, overshoot 1.12 |
| `@keyframes savedfade` | opacity | `0%,55% { opacity:0 }` · `62%,82% { opacity:1 }` · `95%,100% { opacity:0 }` | "Saved" tick fade in/hold/out |

---

## 1a — Menu bar item (`NSStatusItem`): idle / recording / processing / done / failure + NSMenu

### Simulated context (do not implement)

| element | property | design value | note |
|---|---|---|---|
| artboard backdrop | background | `linear-gradient(155deg,#3d4a63 0%,#5c5670 45%,#8f6a72 100%)` | simulated desktop wallpaper |
| artboard | width / radius / shadow | `460px` / `12px` / `0 12px 32px rgba(0,0,0,.18)` | simulation only |
| menu bar strip | height | `26px` | simulated macOS menu bar |
| menu bar strip | corner radius | `7px` | simulation only |
| menu bar strip | background | `rgba(30,30,34,.55)` + `backdrop-filter: blur(20px)` | simulated dark menu bar material |
| menu bar strip | padding / gap / alignment | `0 12px` / `14px` / items right-aligned (`justify-content:flex-end`) | 14px gap is the spacing between status items |
| system clock | text | `Mon 9:41 AM` | macOS-owned, not app UI |
| system clock | font / color | `400 12px` SF Pro / `rgba(255,255,255,.92)`, `font-variant-numeric: tabular-nums` | macOS-owned |

### Idle state

| element | property | design value | note |
|---|---|---|---|
| waveform glyph | svg size | `15 × 13` (`viewBox 0 0 15 13`) | template image; SF Symbol `waveform` [README] |
| waveform glyph | bar count | 4 rounded bars | |
| waveform bar 1 | rect | `x 0.5, y 4.5, w 2, h 4, rx 1` | |
| waveform bar 2 | rect | `x 4.5, y 1.5, w 2, h 10, rx 1` | |
| waveform bar 3 | rect | `x 8.5, y 3.5, w 2, h 6, rx 1` | |
| waveform bar 4 | rect | `x 12.5, y 5, w 2, h 3, rx 1` | |
| waveform bars | fill | `rgba(255,255,255,.92)` | monochrome template image — system tints it |

### Recording state

| element | property | design value | note |
|---|---|---|---|
| capsule | background | `rgba(255,255,255,.14)` | white 14% in dark menu bar |
| capsule | corner radius | `5px` | |
| capsule | padding | `2px 7px 2px 6px` (top/right/bottom/left) | |
| capsule | internal gap | `5px` | dot → time |
| capsule | layout | `inline-flex; align-items:center` | |
| rec dot | size | `7 × 7 px`, `border-radius: 50%` | |
| rec dot | fill | `#ff453a` | `NSColor.systemRed` (dark) |
| rec dot | animation | `recpulse 1.6s ease-in-out infinite` | opacity 100%→35%; never hidden while capturing [README] |
| elapsed time | font | `500 11.5px` SF Mono | medium weight |
| elapsed time | color | `rgba(255,255,255,.95)` | |
| elapsed time | numerals | `font-variant-numeric: tabular-nums` | |
| elapsed time | text | `24:16` | mm:ss |

### Processing state

| element | property | design value | note |
|---|---|---|---|
| spinner | size | `13 × 13 px` | use `NSProgressIndicator` small spinner [README] |
| spinner | shape | `border-radius: 50%` ring | |
| spinner | stroke | `1.5px solid rgba(255,255,255,.25)` | track |
| spinner | leading arc | `border-top-color: rgba(255,255,255,.9)` | |
| spinner | animation | `spin .9s linear infinite` | |

### Done state (transient) — rendered in 2c

| element | property | design value | note |
|---|---|---|---|
| group | layout / gap | `inline-flex; align-items:center` / `5px` | |
| group | animation | `checkpop .4s cubic-bezier(.3,1.4,.5,1) both` | 400 ms spring, overshoot ~1.12 |
| check glyph | svg size | `12 × 12` (`viewBox 0 0 12 12`) | SF Symbol `checkmark.circle.fill` [README] |
| check glyph | circle | `cx 6, cy 6, r 5.4`, fill `#30d158` | `NSColor.systemGreen` |
| check glyph | check path | `d="M3.6 6.2 5.3 7.9 8.5 4.4"` | |
| check glyph | check stroke | `#0b2913`, width `1.4`, `stroke-linecap/linejoin: round`, `fill:none` | dark-green knockout |
| label | text | `Notes ready` | |
| label | font / color | `400 12px` SF Pro / `rgba(255,255,255,.92)` | |
| state | hold duration | holds `4 s`, then reverts to idle glyph | |
| state | click target | clicking opens the session in History | |

### Failure state

| element | property | design value | note |
|---|---|---|---|
| glyph | symbol | `⚠` | SF Symbol `exclamationmark.triangle` [README] |
| glyph | persistence | persists until the menu is opened | |
| menu | extra item | menu gains `Retry Fusion` | |

### NSMenu (dropdown)

| element | property | design value | note |
|---|---|---|---|
| menu panel | width | `224px` | |
| menu panel | corner radius | `8px` | |
| menu panel | background | `rgba(40,40,44,.78)` + `backdrop-filter: blur(30px)` | use native NSMenu material [README] |
| menu panel | border | `0.5px solid rgba(255,255,255,.16)` | |
| menu panel | shadow | `0 10px 34px rgba(0,0,0,.35)` | |
| menu panel | padding | `5px` | |
| menu panel | offset from status item | `margin-top: 5px`, right-aligned under the item | |
| menu item | corner radius | `5px` | highlight radius |
| menu item | padding | `4px 9px` | |
| menu item | layout | `flex; justify-content: space-between` (label left, shortcut right) | shortcuts right-aligned |
| menu item label | font / color | `400 13px` SF Pro / `rgba(255,255,255,.92)` | |
| menu item shortcut | font / color | `400 12px` SF Pro / `rgba(255,255,255,.45)` | |
| highlighted item | background | `#0a82ff` | system accent highlight |
| highlighted item label | color | `#fff` | |
| highlighted item trailing value | font / color | `400 12px` / `rgba(255,255,255,.75)`, tabular-nums | elapsed time on Stop Meeting |
| separator | size / color | `height 1px` / `rgba(255,255,255,.14)` | |
| separator | margin | `5px 9px` | |
| item 1 | text | `Stop Meeting` (`Start Meeting` when idle [README]) | shown highlighted; trailing `24:16` while recording |
| item 2 | text / shortcut | `Open Scratchpad` / `⌥⌘N` | |
| item 3 | — | separator | |
| item 4 | text | `History…` | no shortcut; no trailing value |
| item 5 | text / shortcut | `Settings…` / `⌘,` | |
| item 6 | — | separator | |
| item 7 | text / shortcut | `Quit` / `⌘Q` | |

---

## 1b — Scratchpad, dark HUD (primary)

| element | property | design value | note |
|---|---|---|---|
| panel | width | `312px` | ~300–312 pt [README] |
| panel | corner radius | `12px` | |
| panel | background | `rgba(30,30,33,.9)` + `backdrop-filter: blur(40px)` | `NSVisualEffectView` `.hudWindow` vibrancy [README] |
| panel | border | `0.5px solid rgba(255,255,255,.14)` | hairline |
| panel | shadow | `0 18px 48px rgba(0,0,0,.4)` | |
| panel | window type | non-activating floating `NSPanel` | never steals key focus [README] |
| header | layout | `flex; align-items:center` | |
| header | gap | `8px` | |
| header | padding | `10px 12px 9px` | |
| header | bottom border | `0.5px solid rgba(255,255,255,.1)` | |
| rec dot | size / radius | `7 × 7 px` / `50%` | |
| rec dot | fill | `#ff453a` | `NSColor.systemRed` |
| rec dot | animation | `recpulse 1.6s ease-in-out infinite` | |
| elapsed time | font | `500 12px` SF Mono | |
| elapsed time | color | `rgba(255,255,255,.9)` | |
| elapsed time | numerals | `tabular-nums` | |
| elapsed time | text | `24:16` | |
| spacer | flex | `flex: 1` between time and hint | |
| hotkey hint | text | `⌥⌘N` | |
| hotkey hint | font / color | `400 11px` SF Pro / `rgba(255,255,255,.35)` | |
| Stop button | text | `Stop` | |
| Stop button | font | `500 12px` SF Pro | |
| Stop button | text color | `#ff6961` | |
| Stop button | fill | `rgba(255,69,58,.16)` | systemRed @ 16% |
| Stop button | hover fill | `rgba(255,69,58,.26)` | systemRed @ 26% |
| Stop button | corner radius | `6px` | |
| Stop button | padding | `3px 10px` | |
| Stop button | cursor | `default` | |
| body | padding | `12px 14px 16px` | |
| body | min-height | `150px` | |
| body | font | `400 13px / 1.55` SF Pro | plain `NSTextView`, no formatting, no toolbar [README] |
| body | text color | `rgba(255,255,255,.85)` | |
| body line 1 | text | `pricing objection — follow up w/ annual discount` | at `rgba(255,255,255,.85)` |
| body line 2 | text | `sarah owns the migration doc` | color `rgba(255,255,255,.6)` |
| body line 3 | text | `ask legal about DPA` | at `rgba(255,255,255,.85)`, row is `flex; align-items:center` |
| caret | size | `1.5px wide × 15px tall` | |
| caret | color | `#0a82ff` | accent color |
| caret | margin-left | `2px` | trails the text |
| caret | animation | `caret 1.1s step-end infinite` | blink |

---

## 1c — Scratchpad, light variant

| element | property | design value | note |
|---|---|---|---|
| panel | width | `312px` | |
| panel | corner radius | `12px` | |
| panel | background | `rgba(248,248,247,.92)` + `backdrop-filter: blur(40px)` | light vibrancy material |
| panel | border | `0.5px solid rgba(0,0,0,.1)` | |
| panel | shadow | `0 18px 48px rgba(0,0,0,.22)` | lighter than 1b's `.4` |
| header | layout / gap / padding | `flex; align-items:center` / `8px` / `10px 12px 9px` | |
| header | bottom border | none on the header itself | replaced by an inset separator |
| separator | size / color | `height 1px` / `rgba(0,0,0,.08)` | |
| separator | margin | `0 12px` | inset, does not touch panel edges |
| rec dot | size / radius | `7 × 7 px` / `50%` | |
| rec dot | fill | `#ff3b30` | `NSColor.systemRed` (light) |
| rec dot | animation | `recpulse 1.6s ease-in-out infinite` | |
| elapsed time | font / color | `500 12px` SF Mono / `rgba(0,0,0,.75)` | `tabular-nums` |
| elapsed time | text | `24:16` | |
| spacer | flex | `flex: 1` | no hotkey hint in this variant |
| Stop button | text | `Stop` | |
| Stop button | font / color | `500 12px` SF Pro / `rgba(0,0,0,.7)` | |
| Stop button | fill | `rgba(0,0,0,.06)` | bordered gray button |
| Stop button | border | `0.5px solid rgba(0,0,0,.08)` | |
| Stop button | hover fill | `rgba(0,0,0,.1)` | |
| Stop button | corner radius / padding | `6px` / `3px 10px` | |
| Stop button | cursor | `default` | |
| body | padding / min-height | `12px 14px 16px` / `150px` | |
| body | font | `400 13px / 1.55` SF Pro | |
| body | text color | `rgba(0,0,0,.82)` | |
| body line 1 | text | `pricing objection — follow up w/ annual discount` | |
| body line 2 | text | `sarah owns the migration doc` | color `rgba(0,0,0,.5)` |
| body line 3 | text | `ask legal about DPA` | row `flex; align-items:center` |
| caret | size / color / margin / animation | `1.5 × 15px` / `#0a82ff` / `margin-left 2px` / `caret 1.1s step-end infinite` | same accent caret as dark |

---

## 1d — History window

| element | property | design value | note |
|---|---|---|---|
| window | width | `760px` | ~760 × 470 [README] |
| window | corner radius | `11px` | |
| window | background | `#fff` | |
| window | border | `0.5px solid rgba(0,0,0,.14)` | |
| window | shadow | `0 22px 60px rgba(0,0,0,.22)` | simulated window shadow |
| window | layout | `flex` row, `overflow:hidden` | sidebar + detail |

### Sidebar

| element | property | design value | note |
|---|---|---|---|
| sidebar | width | `236px` | |
| sidebar | background | `rgba(242,241,239,.96)` (`#F2F1EF`) | source-list material (`.sidebar` vibrancy) [README] |
| sidebar | right border | `0.5px solid rgba(0,0,0,.1)` | hairline |
| traffic lights | size / gap | `12 × 12 px` circles / `8px` | OS-drawn, not app UI |
| traffic lights | colors | `#ff5f57`, `#febc2e`, `#28c840` | OS-drawn |
| traffic lights | padding | `16px 16px 14px` | defines sidebar top inset |
| row list | padding | `2px 8px 12px` | |
| row list | gap | `2px` | between rows |
| session row | corner radius | `6px` | |
| session row | padding | `7px 10px` | |
| session row (selected) | fill | `rgba(0,0,0,.07)` | black 7% |
| session row (unselected) | fill | none | |
| row line 1 | layout / gap | `flex; align-items: baseline` / `6px` | |
| row title | font / color | `500 13px` SF Pro / `#1d1d1f` | |
| row title | truncation | `flex:1; white-space:nowrap; overflow:hidden; text-overflow:ellipsis` | |
| row meta | font / color | `400 11px` SF Pro / `rgba(0,0,0,.45)` | right-aligned |
| row line 2 (date) | font / color | `400 11px` SF Pro / `rgba(0,0,0,.45)` | |
| row line 2 (date) | margin-top | `1px` | |
| fusing spinner | size | `9 × 9 px`, `border-radius:50%` | inline in meta |
| fusing spinner | stroke | `1.5px solid rgba(0,0,0,.15)`, top `rgba(0,0,0,.5)` | |
| fusing spinner | animation | `spin .9s linear infinite` | |
| fusing meta | layout / gap | `inline-flex; align-items:center` / `4px` | spinner + label |
| `recovered` tag | text | `recovered` | crash-recovered sessions |
| `recovered` tag | font | `500 9px` SF Pro | |
| `recovered` tag | color | `#8a6a00` | |
| `recovered` tag | fill | `rgba(255,204,0,.22)` | `NSColor.systemYellow` @ 22% |
| `recovered` tag | corner radius | `4px` | |
| `recovered` tag | padding | `1.5px 5px` | |
| `recovered` tag | letter-spacing | `.02em` | |
| failed meta | color | `#e0483e` | failure text token |
| row 1 | content | title `Acme renewal call` · meta `42 min` · date `Today, 9:00 AM` | selected row |
| row 2 | content | title `Design crit — panels` · spinner + `fusing` · date `Yesterday, 2:30 PM` | |
| row 3 | content | title `1:1 with Priya` · tag `recovered` + meta `28 min` · date `Yesterday, 11:00 AM` | tag sits left of the duration |
| row 4 | content | title `Infra standup` · meta `failed` (`#e0483e`) · date `Aug 14, 9:30 AM` | |

### Detail toolbar

| element | property | design value | note |
|---|---|---|---|
| toolbar | padding | `12px 16px` | |
| toolbar | gap | `10px` | |
| toolbar | bottom border | `0.5px solid rgba(0,0,0,.08)` | |
| toolbar | layout | `flex; align-items:center`, spacer (`flex:1`) after the segmented control | buttons right-aligned |
| segmented control | background | `rgba(0,0,0,.05)` | track |
| segmented control | corner radius | `7px` | |
| segmented control | padding | `1.5px` | track inset |
| selected segment | text | `Notes` | |
| selected segment | font / color | `500 12px` SF Pro / `#1d1d1f` | |
| selected segment | fill / radius | `#fff` / `6px` | white pill |
| selected segment | shadow | `0 1px 2px rgba(0,0,0,.12)` | |
| selected segment | padding | `3px 12px` | |
| unselected segment | text | `Transcript` | |
| unselected segment | font / color | `400 12px` SF Pro / `rgba(0,0,0,.6)` | |
| unselected segment | padding | `3px 12px` | |
| toolbar button | font | `400 12px` SF Pro | |
| toolbar button | color | `rgba(0,0,0,.65)` | |
| toolbar button | border | `0.5px solid rgba(0,0,0,.14)` | |
| toolbar button | corner radius | `6px` | |
| toolbar button | padding | `3px 10px` | |
| toolbar button | background | `#fff` | |
| toolbar button | hover background | `rgba(0,0,0,.04)` | |
| button 1 | text | `Export` | |
| button 2 | text | `Retry Fusion` | |
| button 3 | text | `Export Eval Case` | `white-space: nowrap` |
| button 4 | text | `Delete` | |
| button 4 | color | `#e0483e` | destructive |
| button 4 | hover background | `rgba(224,72,62,.06)` | |

### Notes pane

| element | property | design value | note |
|---|---|---|---|
| pane | padding | `20px 24px 26px` | |
| pane | overflow | `hidden` | |
| session title | font / color | `600 17px` SF Pro / `#1d1d1f` | |
| session title | text | `Acme renewal call` | |
| meta line | font / color | `400 11.5px` SF Pro / `rgba(0,0,0,.45)` | |
| meta line | margin | `3px 0 14px` | |
| meta line | text | `Today, 9:00–9:42 AM · fused from 3 fragments` | en-dash in the time range |
| section label | font | `600 12px` SF Pro | |
| section label | color | `rgba(0,0,0,.5)` | |
| section label | transform | `text-transform: uppercase` | |
| section label | letter-spacing | `.05em` | |
| section label 1 | text / margin | `Summary` (renders `SUMMARY`) / `margin-bottom: 6px` | |
| section label 2 | text / margin | `Action items` (renders `ACTION ITEMS`) / `margin: 16px 0 6px` | |
| body text | font | `400 13px / 1.55` SF Pro | |
| body text | color | `#333` | |
| body text | wrapping | `text-wrap: pretty` | |
| summary body | text | `Renewal is likely but blocked on pricing. Dan pushed back on the per-seat increase; open to annual prepay at the current rate. Security review is done — only the DPA remains.` | |
| action item list | layout / gap | `flex column` / `5px` | |
| action item list | font / color | `400 13px / 1.45` SF Pro / `#333` | note the 1.45 line-height, not 1.55 |
| action item row | gap | `8px` | checkbox → text |
| checkbox | size | `13 × 13 px` | |
| checkbox | corner radius | `4px` | |
| checkbox | border | `1.5px solid rgba(0,0,0,.25)` | |
| checkbox | fill | none (all three unchecked) | |
| checkbox | margin-top / flex | `2px` / `flex: none` | optical baseline alignment |
| checkbox | interactivity | static glyph, **not interactive** [README] | v0 stores no done-ness |
| action item 1 | text | `Send annual-prepay quote to Dan by Thursday` | |
| action item 2 | text | `Ask legal to review the updated DPA` | |
| action item 3 | text | `Sarah: share migration doc with their platform team` | |

### Validator warning card (inline in the notes flow)

| element | property | design value | note |
|---|---|---|---|
| card | layout | `flex; gap:8px; align-items:flex-start` | icon + text |
| card | margin-top | `10px` | sits between summary body and next section label |
| card | padding | `8px 10px` | |
| card | corner radius | `7px` | |
| card | fill | `rgba(255,204,0,.12)` | `NSColor.systemYellow` @ 12% |
| card | border | `0.5px solid rgba(178,134,0,.25)` | |
| warning icon | svg size | `13 × 12` (`viewBox 0 0 13 12`) | SF Symbol `exclamationmark.triangle` [README] |
| warning icon | triangle path | `d="M6.5 1 12 11H1L6.5 1Z"`, fill `#e6a700` | |
| warning icon | exclamation bar | `rect x 5.9, y 4.4, w 1.2, h 3.2, rx 0.6`, fill `#fff` | |
| warning icon | exclamation dot | `circle cx 6.5, cy 9, r 0.75`, fill `#fff` | |
| warning icon | placement | `flex:none; margin-top: 2px` | |
| warning text | font | `400 12px / 1.5` SF Pro | |
| warning text | color | `rgba(0,0,0,.65)` | |
| warning text | full string | `Validator: "by Thursday" has no matching span in the transcript — verify before sending.` | straight double quotes around the span |
| `Validator:` prefix | weight / color | `600` / `rgba(0,0,0,.75)` | |

---

## 1e — Settings window

| element | property | design value | note |
|---|---|---|---|
| window | width | `520px` | |
| window | corner radius | `11px` | |
| window | background | `#f5f4f2` | window background |
| window | border | `0.5px solid rgba(0,0,0,.14)` | |
| window | shadow | `0 22px 60px rgba(0,0,0,.22)` | simulated window shadow |
| titlebar | padding | `14px 16px 10px` | |
| traffic lights | size / gap / position | `12 × 12 px` / `8px` / `position:absolute; left:16px` | OS-drawn |
| traffic lights | colors | `#ff5f57`, `rgba(0,0,0,.12)`, `rgba(0,0,0,.12)` | minimize + zoom disabled (fixed-size settings window) |
| window title | text | `Settings` | |
| window title | font / color | `600 13px` SF Pro / `#1d1d1f` | centered |
| content stack | padding | `10px 20px 24px` | |
| content stack | layout / gap | `flex column` / `14px` | between group cards |
| group card | background | `#fff` | |
| group card | border | `0.5px solid rgba(0,0,0,.1)` | |
| group card | corner radius | `9px` | |
| group card | padding | `0 14px` | horizontal only; rows supply vertical padding |
| row | layout / gap | `flex; align-items:center` / `12px` | |
| row | padding | `11px 0` | |
| row separator | border-bottom | `0.5px solid rgba(0,0,0,.08)` | between rows inside a group; absent on the last row |
| row label | font / color | `400 13px` SF Pro / `#1d1d1f` | |
| row caption | font / color | `400 11px` SF Pro / `rgba(0,0,0,.45)` | |
| row caption | margin-top | `1px` | |
| label column | flex | `flex: 1` | control right-aligned |
| group 1 | rows | 1 row: Anthropic API Key | |
| API key label | text | `Anthropic API Key` | |
| API key caption | text | `Stored in the macOS Keychain` | store in Keychain, never plist [README] |
| API key field | text | `••••••••••7f2a` | masked; edit-in-place secure field [README] |
| API key field | font / color | `400 13px` monospace / `rgba(0,0,0,.55)` | SF Mono |
| API key field | background | `rgba(0,0,0,.04)` | |
| API key field | border | `0.5px solid rgba(0,0,0,.12)` | |
| API key field | corner radius / padding | `6px` / `4px 10px` | |
| API key field | letter-spacing | `.14em` | |
| group 2 | rows | 2 rows: Whisper Model, Lookback Window | separated by hairline |
| Whisper Model label | text | `Whisper Model` | |
| Whisper Model popup | value | `small.en` | default [README] |
| Whisper Model popup | options | `tiny.en` / `base.en` / `small.en` / `large-v3-turbo` [README] | flag `large-v3-turbo` as a large download |
| Lookback label | text | `Lookback Window` | |
| Lookback caption | text | `Advanced — how far back fusion anchors a fragment in the transcript` | |
| Lookback popup | value | `20 seconds` | v0 default |
| Lookback popup | sizing | `white-space: nowrap; flex: none` | |
| popup button | layout / gap | `inline-flex; align-items:center` / `6px` | label → chevron |
| popup button | font / color | `400 13px` SF Pro / `#1d1d1f` | |
| popup button | background | `#fff` | |
| popup button | border | `0.5px solid rgba(0,0,0,.16)` | |
| popup button | corner radius / padding | `6px` / `3px 10px` | |
| popup button | shadow | `0 1px 1.5px rgba(0,0,0,.08)` | |
| popup chevron | svg size | `8 × 10` (`viewBox 0 0 8 10`) | up/down chevrons |
| popup chevron | path | `d="M1.5 3.5 4 1l2.5 2.5M1.5 6.5 4 9l2.5-2.5"` | |
| popup chevron | stroke | `rgba(0,0,0,.5)`, width `1.3`, `linecap/linejoin: round`, `fill:none` | |
| group 3 | rows | 1 row: Launch at Login | |
| Launch label | text | `Launch at Login` | |
| switch | size | `36 × 22 px` | standard `NSSwitch` |
| switch | corner radius | `11px` | |
| switch | on fill | `#34c759` | `NSColor.systemGreen` |
| switch | padding | `2px`, knob aligned `flex-end` (on) | |
| switch knob | size / radius | `18 × 18 px` / `50%` | |
| switch knob | fill / shadow | `#fff` / `0 1px 2px rgba(0,0,0,.25)` | |

---

## 2a — Scratchpad empty / no-meeting states

Both panels share 1b's chrome except where noted.

| element | property | design value | note |
|---|---|---|---|
| panel (both) | width | `300px` | narrower than 1b's `312px` |
| panel (both) | corner radius | `12px` | |
| panel (both) | background | `rgba(30,30,33,.9)` + `blur(40px)` | HUD material |
| panel (both) | border | `0.5px solid rgba(255,255,255,.14)` | |
| panel (both) | shadow | `0 18px 48px rgba(0,0,0,.4)` | |
| header (both) | layout / gap / padding | `flex; align-items:center` / `8px` / `10px 12px 9px` | |
| header (both) | bottom border | `0.5px solid rgba(255,255,255,.1)` | |
| body (both) | padding | `12px 14px 16px` | |
| body (both) | min-height | `130px` | empty-state height |
| body (both) | font | `400 13px / 1.55` SF Pro | |
| **empty (recording)** rec dot | size / fill / animation | `7 × 7 px` / `#ff453a` / `recpulse 1.6s ease-in-out infinite` | |
| **empty** elapsed | font / color / text | `500 12px` SF Mono, tabular / `rgba(255,255,255,.9)` / `00:04` | |
| **empty** header | hotkey hint | absent in this state | |
| **empty** Stop button | text / font / color | `Stop` / `500 12px` SF Pro / `#ff6961` | |
| **empty** Stop button | fill / hover / radius / padding | `rgba(255,69,58,.16)` / `rgba(255,69,58,.26)` / `6px` / `3px 10px` | |
| **empty** placeholder row | layout | `flex; align-items:center` | caret precedes text |
| **empty** placeholder | text | `Jot a fragment — plain text, saved as you type` | |
| **empty** placeholder | color | `rgba(255,255,255,.32)` | white 32% |
| **empty** caret | size / color | `1.5 × 15px` / `#0a82ff` | accent |
| **empty** caret | margin-right | `2px` | leads the placeholder |
| **empty** caret | animation | `caret 1.1s step-end infinite` | |
| **no-meeting** dot | size / radius | `7 × 7 px` / `50%` | |
| **no-meeting** dot | fill | `rgba(255,255,255,.25)` | white 25% |
| **no-meeting** dot | animation | none — static | |
| **no-meeting** label | text | `No meeting` | |
| **no-meeting** label | font / color | `400 12px` SF Pro (not mono) / `rgba(255,255,255,.5)` | |
| **no-meeting** button | text | `Start Meeting` | replaces Stop |
| **no-meeting** button | font / color | `500 12px` SF Pro / `#fff` | |
| **no-meeting** button | fill | `#0a82ff` | system accent |
| **no-meeting** button | hover fill | `#2b93ff` | |
| **no-meeting** button | corner radius / padding | `6px` / `3px 10px` | |
| **no-meeting** body hint | text | `Fragments typed here are discarded unless a meeting is recording.` | |
| **no-meeting** body hint | color | `rgba(255,255,255,.32)` | |
| **no-meeting** body | caret | none | |

---

## 2b — Summon animation

| element | property | design value | note |
|---|---|---|---|
| stage | size | `360 × 262 px`, radius `12px` | simulated desktop, not app UI |
| stage | background | `linear-gradient(155deg,#3d4a63 0%,#5c5670 45%,#8f6a72 100%)` | simulation only |
| panel | position | `top: 20px; left: 30px; right: 30px` | summoned near top of screen |
| panel | corner radius / background | `12px` / `rgba(30,30,33,.9)` + `blur(40px)` | |
| panel | border / shadow | `0.5px solid rgba(255,255,255,.14)` / `0 18px 48px rgba(0,0,0,.4)` | |
| panel | transform-origin | `top center` | scale grows downward from the top edge |
| panel | demo animation | `summon 3.4s cubic-bezier(.2,.8,.3,1) infinite` | loop only; real timings below |
| summon (in) | duration / easing | `180 ms` ease-out | [README] |
| summon (in) | properties | opacity `0 → 1`, scale `.96 → 1` | |
| dismiss (out) | duration | `140 ms` | scale `1 → .98`, opacity `1 → 0` per keyframe |
| Reduce Motion | behavior | fade only, no scale | [README] |
| focus | behavior | never steals key focus from the meeting app | `.nonactivatingPanel` |
| trigger | shortcut | `⌥⌘N` global hotkey | user-remappable later [README] |
| header | gap / padding / border | `8px` / `10px 12px 9px` / bottom `0.5px solid rgba(255,255,255,.1)` | |
| rec dot | size / fill / animation | `7 × 7 px` / `#ff453a` / `recpulse 1.6s ease-in-out infinite` | |
| elapsed | font / color / text | `500 12px` SF Mono, tabular / `rgba(255,255,255,.9)` / `24:16` | |
| Stop button | text / font / color / fill / radius / padding | `Stop` / `500 12px` / `#ff6961` / `rgba(255,69,58,.16)` / `6px` / `3px 10px` | no hover state defined in this artboard |
| body | padding | `12px 14px 14px` | note the `14px` bottom, unlike 1b's `16px` |
| body | min-height | `96px` | |
| body | font / color | `400 13px / 1.55` SF Pro / `rgba(255,255,255,.85)` | |
| body line 1 | text | `pricing objection — follow up` | |
| body line 2 | text | `sarah owns the migration doc` | color `rgba(255,255,255,.6)`, row `flex; align-items:center` |
| caret | size / color / margin / animation | `1.5 × 15px` / `#0a82ff` / `margin-left 2px` / `caret 1.1s step-end infinite` | |
| behavior annotation | text | `⌥⌘N · FADES + SCALES IN · KEY FOCUS STAYS IN MEETING APP` | spec annotation of the interaction |

---

## 2c — Stop → processing → ready sequence

| element | property | design value | note |
|---|---|---|---|
| menu bar strip (each of 3) | height / radius | `26px` / `7px` | simulated macOS menu bar |
| menu bar strip | background | `rgba(30,30,34,.55)` + `blur(20px)` | simulation |
| menu bar strip | padding / gap / alignment | `0 12px` / `14px` / right-aligned | |
| system clock (all 3) | text / font / color | `Mon 9:41 AM` / `400 12px` SF Pro / `rgba(255,255,255,.92)` | OS-owned |
| **step 1** | stage label | `STOP CLICKED` | |
| **step 1** capsule | background / radius / padding / gap | `rgba(255,255,255,.14)` / `5px` / `2px 7px 2px 6px` / `5px` | |
| **step 1** capsule | opacity | `.45` | recording capsule fading out on stop |
| **step 1** dot | size / fill / animation | `7 × 7 px` / `#ff453a` / none (pulse stopped) | |
| **step 1** elapsed | font / color / text | `500 11.5px` SF Mono / `rgba(255,255,255,.95)` / `41:52` | final elapsed value |
| **step 2** | stage label / timing | `FUSING · ~20 S` | ~20 s typical |
| **step 2** spinner | size | `13 × 13 px`, `border-radius:50%` | `NSProgressIndicator` small |
| **step 2** spinner | stroke | `1.5px solid rgba(255,255,255,.25)`, top `rgba(255,255,255,.9)` | |
| **step 2** spinner | animation | `spin .9s linear infinite` | |
| **step 3** | stage label / timing | `DONE · HOLDS 4 S` | then reverts to idle glyph |
| **step 3** group | layout / gap | `inline-flex; align-items:center` / `5px` | |
| **step 3** group | animation | `checkpop .4s cubic-bezier(.3,1.4,.5,1) both` | 400 ms spring, overshoot 1.12 |
| **step 3** check | svg size / circle | `12 × 12` / `cx 6, cy 6, r 5.4` fill `#30d158` | `NSColor.systemGreen` |
| **step 3** check | path / stroke | `M3.6 6.2 5.3 7.9 8.5 4.4` / `#0b2913`, width `1.4`, round caps | |
| **step 3** label | text / font / color | `Notes ready` / `400 12px` SF Pro / `rgba(255,255,255,.92)` | |
| sequence footnote | text | `"Notes ready" is clickable → opens session in History. If fusion fails: ⚠ glyph persists until the menu is opened; menu gains "Retry Fusion".` | behavior spec |

---

## 2d — History empty state

| element | property | design value | note |
|---|---|---|---|
| window | size | `560 × 330 px` | empty-state artboard size |
| window | corner radius | `11px` | |
| window | background | `#fff` | no sidebar shown when empty |
| window | border | `0.5px solid rgba(0,0,0,.14)` | |
| window | shadow | `0 22px 60px rgba(0,0,0,.22)` | simulated window shadow |
| traffic lights | size / gap / colors | `12 × 12 px` / `8px` / `#ff5f57`, `#febc2e`, `#28c840` | OS-drawn |
| traffic lights | padding | `16px 16px 0` | |
| content stack | layout | `flex column; align-items:center; justify-content:center` | vertically + horizontally centered |
| content stack | gap | `10px` | |
| content stack | padding-bottom | `24px` | optical centering offset |
| waveform glyph | svg size | `26 × 22` (`viewBox 0 0 26 22`) | SF Symbol `waveform` [README] |
| waveform bar 1 | rect | `x 1, y 8, w 3, h 6, rx 1.5` | |
| waveform bar 2 | rect | `x 7, y 3, w 3, h 16, rx 1.5` | |
| waveform bar 3 | rect | `x 13, y 6, w 3, h 10, rx 1.5` | |
| waveform bar 4 | rect | `x 19, y 9, w 3, h 4, rx 1.5` | |
| waveform bars | fill | `rgba(0,0,0,.18)` | gray |
| title | text | `No sessions yet` | |
| title | font / color | `600 14px` SF Pro / `rgba(0,0,0,.65)` | |
| caption | text | `Start a meeting from the menu bar. Notes land here when fusion finishes.` | |
| caption | font / color | `400 12px` SF Pro / `rgba(0,0,0,.4)` | |
| caption | alignment / width / wrapping | `text-align:center` / `max-width: 280px` / `text-wrap: pretty` | |
| button | text | `Start Meeting` | |
| button | margin-top | `4px` | on top of the `10px` stack gap |
| button | font / color | `500 12px` SF Pro / `#1d1d1f` | |
| button | background | `#fff` | bordered button |
| button | border | `0.5px solid rgba(0,0,0,.16)` | |
| button | corner radius / padding | `6px` / `4px 12px` | |
| button | shadow | `0 1px 1.5px rgba(0,0,0,.08)` | |
| button | hover background | `rgba(0,0,0,.03)` | |

---

## 2e — Saved tick + motion spec

### Scratchpad with "Saved" tick

| element | property | design value | note |
|---|---|---|---|
| panel | width | `300px` | |
| panel | corner radius / background | `12px` / `rgba(30,30,33,.9)` + `blur(40px)` | |
| panel | border / shadow | `0.5px solid rgba(255,255,255,.14)` / `0 18px 48px rgba(0,0,0,.4)` | |
| header | layout / gap / padding | `flex; align-items:center` / `8px` / `10px 12px 9px` | |
| header | bottom border | `0.5px solid rgba(255,255,255,.1)` | |
| rec dot | size / fill / animation | `7 × 7 px` / `#ff453a` / `recpulse 1.6s ease-in-out infinite` | |
| elapsed | font / color / text | `500 12px` SF Mono, tabular / `rgba(255,255,255,.9)` / `24:16` | |
| spacer | flex | `flex: 1` between elapsed and Saved | Saved sits immediately left of Stop |
| Saved label | text | `Saved` | |
| Saved label | font | `400 11px` SF Pro | |
| Saved label | color | `rgba(255,255,255,.45)` | white 45% |
| Saved label | animation | `savedfade 4s ease-in-out infinite` | demo loop; real behavior: shows on persist, fades out after `2 s` |
| Saved label | spinner | none — no spinner ever | |
| Stop button | text / font / color | `Stop` / `500 12px` SF Pro / `#ff6961` | |
| Stop button | fill / radius / padding | `rgba(255,69,58,.16)` / `6px` / `3px 10px` | |
| body | padding | `12px 14px 16px` | |
| body | min-height | `110px` | |
| body | font / color | `400 13px / 1.55` SF Pro / `rgba(255,255,255,.85)` | |
| body line 1 | text | `pricing objection — follow up` | |
| body line 2 | text | `ask legal about DPA` | row `flex; align-items:center` |
| caret | size / color / margin / animation | `1.5 × 15px` / `#0a82ff` / `margin-left 2px` / `caret 1.1s step-end infinite` | |

### Motion & interaction spec card (behavior contract)

| element | property | design value | note |
|---|---|---|---|
| card | width | `320px` | reference card, not app UI — the values it states are the contract |
| card | corner radius / background | `10px` / `#fff` | |
| card | border / shadow | `0.5px solid rgba(0,0,0,.1)` / `0 8px 24px rgba(0,0,0,.08)` | |
| card | padding / gap | `16px 18px` / `9px` | |
| card | font / color | `400 12px / 1.5` SF Pro / `#333` | |
| card heading | text | `MOTION & INTERACTION SPEC` | |
| card heading | font / letter-spacing / color | `600 11px` monospace / `.08em` / `rgba(0,0,0,.45)` | |
| spec row | layout / gap | `flex` / `10px`; label column `width: 96px; flex: none`, color `rgba(0,0,0,.45)` | |
| spec `Panel summon` | value | `180 ms ease-out, opacity + scale .96→1; dismiss 140 ms. Reduce Motion → fade only.` | |
| spec `Rec dot` | value | `1.6 s opacity pulse. Never hidden while capturing, incl. panel closed.` | |
| spec `Saved tick` | value | `In-progress fragment persists as a mutable row on ~1 s debounce; a burst boundary (≥3 s pause / newline) freezes it. Tick shows on persist, fades out after 2 s. No spinner.` | |
| spec `Notes ready` | value | `Checkmark pops (400 ms spring), holds 4 s, reverts to idle glyph.` | |
| spec `Esc` | value | `Dismisses panel; recording continues (dot stays in menu bar).` | |

---

## 3a — Journey map (five flows, each terminating at the menu bar)

Turn header `3` · `User journeys — every path reachable, every path returns to the menu bar`.
Artboard label: `3a` `Journey map — five flows, each terminating at the menu bar (home)`;
`data-screen-label="3a Journey map"`.

This artboard is a **documentation diagram**, not app UI — do not draw the card. The node labels,
arrow labels and ordering below are the navigation contract to implement.

### Card chrome (diagram container — do not implement)

| element | property | design value | note |
|---|---|---|---|
| card | width | `840px` | diagram sheet |
| card | corner radius | `11px` | |
| card | background | `#fff` | |
| card | border | `0.5px solid rgba(0,0,0,.12)` | |
| card | shadow | `0 12px 36px rgba(0,0,0,.1)` | |
| card | padding | `22px 24px 18px` | |
| card | layout / gap | `flex; flex-direction:column` / `18px` | one lane per journey |
| lane | layout / gap | `flex; flex-direction:column` / `7px` | heading over node row |
| lane heading | font | `600 10px` SF Mono / `ui-monospace,Menlo,monospace` | |
| lane heading | letter-spacing / color | `.08em` / `rgba(0,0,0,.45)` | |
| node row | layout | `flex; align-items:center; flex-wrap:wrap` | |
| node row | gap | `6px 4px` (row / column) | |

### Node vocabulary

| element | property | design value | note |
|---|---|---|---|
| node (menu-bar / home) | font / color / background | `500 11.5px` SF Pro / `#fff` / `#2e2e33` | dark node = menu bar surface |
| node (menu-bar / home) | corner radius / padding | `6px` / `4px 10px` | |
| node (menu-bar / home) | wrapping | `white-space: nowrap` | |
| node (window / panel) | font / color / background | `500 11.5px` SF Pro / `#1d1d1f` / `#fff` | light node = a window or panel |
| node (window / panel) | border | `0.5px solid rgba(0,0,0,.16)` | |
| node (window / panel) | corner radius / padding | `6px` / `4px 10px` | |
| node (window / panel) | shadow | `0 1px 2px rgba(0,0,0,.06)` | |
| node (external app) | font / color / background | `500 11.5px` SF Pro / `rgba(0,0,0,.55)` / `rgba(0,0,0,.05)` | used only by `Any app` |
| node (success) | color / background | `#0b6329` / `rgba(48,209,88,.16)` | used by `✓ Notes ready · 4 s` |
| node (failure) | color / background | `#8a4a00` / `rgba(255,159,10,.16)` | used by `⚠ Menu bar · failed` |
| home marker | outline | `1.5px solid rgba(48,209,88,.55)`, `outline-offset: 1.5px` | marks the terminal node of every flow |
| home marker | label suffix | ` ⌂` appended to the node text | |
| node with rec dot | layout / gap | `inline-flex; align-items:center` / `6px` | |
| inline rec dot | size / radius / fill | `6 × 6 px` / `50%` / `#ff453a` | smaller than the 7 px status-item dot |
| inline rec dot | animation | `recpulse 1.6s ease-in-out infinite` | |
| inline spinner | size / radius | `9 × 9 px` / `50%` | |
| inline spinner | stroke | `1.5px solid rgba(255,255,255,.3)`, `border-top-color: #fff` | on dark node |
| inline spinner | animation | `spin .9s linear infinite` | |
| arrow group | layout / padding | `inline-flex; flex-direction:column; align-items:center` / `0 4px` | label above glyph |
| arrow label | font / color | `500 9px` SF Mono / `rgba(0,0,0,.45)` | |
| arrow label | wrapping | `white-space: nowrap` | |
| arrow glyph | text | `⟶` (forward) · `⟲` (loop back to same surface) | |
| arrow glyph | font / color | `400 13px / 0.8` SF Pro / `rgba(0,0,0,.35)` | |

### J1 — lane `J1 · RECORD & FUSE (HAPPY PATH)`

| # | node / transition | literal | note |
|---|---|---|---|
| 1 | node | `Menu bar · idle` | dark node |
| → | arrow | `Start Meeting` | |
| 2 | node | `Recording` | dark node + inline rec dot |
| → | arrow | `⌥⌘N` | |
| 3 | node | `Scratchpad` | light node |
| → | arrow | `Stop · or Esc first` | |
| 4 | node | `Fusing` | dark node + inline spinner |
| → | arrow | `auto · ~20 s` | |
| 5 | node | `✓ Notes ready · 4 s` | success node |
| → | arrow | `auto` | |
| 6 | node | `Menu bar · idle ⌂` | dark node + home outline |

### J2 — lane `J2 · HOTKEY FIRST, NO MEETING RUNNING`

| # | node / transition | literal | note |
|---|---|---|---|
| 1 | node | `Any app` | external-app node |
| → | arrow | `⌥⌘N` | |
| 2 | node | `Scratchpad · no meeting` | light node |
| → | arrow | `Start Meeting` | |
| 3 | node | `Scratchpad · recording` | light node + inline rec dot |
| → | arrow | `Esc · rec continues` | |
| 4 | node | `Menu bar · recording ⌂` | dark node + inline rec dot + home outline |

### J3 — lane `J3 · REVIEW & EXPORT`

| # | node / transition | literal | note |
|---|---|---|---|
| 1 | node | `Menu bar` | dark node |
| → | arrow | `History… · or click ✓` | |
| 2 | node | `History` | light node |
| ⟲ | arrow | `Notes ⇄ Transcript` | glyph is `⟲` — in-place toggle, not a new surface |
| 3 | node | `Export / Eval / Delete` | light node |
| → | arrow | `⌘W · non-modal` | |
| 4 | node | `Menu bar ⌂` | dark node + home outline |

### J4 — lane `J4 · FUSION FAILURE & RECOVERY`

| # | node / transition | literal | note |
|---|---|---|---|
| 1 | node | `⚠ Menu bar · failed` | failure node |
| → | arrow | `open menu` | |
| 2 | node | `Retry Fusion` | light node |
| → | arrow | `also in History` | retry is reachable from both menu and History |
| 3 | node | `Fusing` | dark node + inline spinner |
| → | arrow | `✓ or ⚠ again` | |
| 4 | node | `Menu bar ⌂` | dark node + home outline |
| 5 | footnote | `no dead end: ⚠ never blocks Start Meeting` | trailing annotation on the lane |
| footnote | font / color / padding-left | `400 10px` SF Mono / `rgba(0,0,0,.4)` / `4px` | |

### J5 — lane `J5 · SETTINGS`

| # | node / transition | literal | note |
|---|---|---|---|
| 1 | node | `Menu bar` | dark node |
| → | arrow | `Settings… · ⌘,` | |
| 2 | node | `Settings` | light node |
| → | arrow | `changes apply live · ⌘W` | no Save/Cancel |
| 3 | node | `Menu bar ⌂` | dark node + home outline |

---

## 3b — Reachability & return proof

Artboard label: `3b` `Reachability & return proof — entry paths and guaranteed way home per surface`;
`data-screen-label="3b Reachability"`. Documentation table — do not draw; the rows are the contract.

### Card chrome (do not implement)

| element | property | design value | note |
|---|---|---|---|
| card | width | `620px` | |
| card | corner radius | `11px` | |
| card | background | `#fff` | |
| card | border | `0.5px solid rgba(0,0,0,.12)` | |
| card | shadow | `0 12px 36px rgba(0,0,0,.1)` | |
| card | padding | `20px 22px` | |
| table | layout | `display:grid; grid-template-columns: 120px 1fr 1fr; gap: 0` | |
| table | font / color | `400 12px / 1.45` SF Pro / `#333` | |
| header cell | font / letter-spacing / color | `600 10px` SF Mono / `.08em` / `rgba(0,0,0,.45)` | |
| header cell | padding | `0 0 8px` | |
| header cells | text | `SURFACE` · `REACHED BY` · `WAY BACK HOME` | |
| body cell col 1 | font-weight / color | `600` / `#1d1d1f` | |
| body cell col 1 | padding | `9px 8px 9px 0` | |
| body cell col 2 | padding | `9px 12px 9px 0` | |
| body cell col 3 | padding | `9px 0` | |
| every body cell | top border | `0.5px solid rgba(0,0,0,.08)` | row separator |

### Table content (verbatim)

| surface | reached by | way back home |
|---|---|---|
| `Menu bar` | `Always present (NSStatusItem) — the home node; survives every state incl. failure` | `Is home — nothing can hide it while capturing` |
| `Scratchpad` | `⌥⌘N from any app · menu → Open Scratchpad` | `Esc or ⌥⌘N again — never steals key focus, so "back" is free; recording unaffected` |
| `History` | `Menu → History… · click "✓ Notes ready" · empty-state Start Meeting loops to J1` | `⌘W / close button — non-modal, no unsaved state, Delete confirms first` |
| `Settings` | `Menu → Settings… · ⌘,` | `⌘W — no Save/Cancel; every control applies immediately` |

### Invariants callout

| element | property | design value | note |
|---|---|---|---|
| callout | margin-top / padding | `16px` / `10px 12px` | |
| callout | corner radius / background | `7px` / `rgba(0,0,0,.035)` | |
| callout | font / color | `400 11.5px / 1.55` SF Pro / `rgba(0,0,0,.6)` | |
| callout lead | text / font / color | `Invariants.` / `600` weight / `rgba(0,0,0,.75)` | |
| callout body | text | `No modal states anywhere. Every window closes with ⌘W; the panel dismisses with Esc without side effects. The status item is the persistent root: every journey starts and ends there, and the recording indicator cannot be dismissed while capture is live — when fullscreen hides the menu bar, the recording chip (4a) takes over as indicator and stop affordance. Quit while recording asks to stop first — the only confirm in the app besides Delete.` | `4a` is a link to the 4a artboard |
| rule | modality | no modal states anywhere | |
| rule | window close | every window closes with `⌘W` | |
| rule | panel dismiss | `Esc`, with no side effects | |
| rule | root surface | status item is the persistent root of every journey | |
| rule | indicator | recording indicator cannot be dismissed while capture is live | |
| rule | fullscreen fallback | recording chip (4a) takes over as indicator + stop affordance | |
| rule | quit while recording | asks to stop first | |
| rule | confirms | exactly two in the app: Quit-while-recording and Delete | |

---

## 4a — Recording chip (fullscreen-safe stop)

Turn header `4` · `Fullscreen-safe stop — the indicator follows the mic, not the menu bar`.
Artboard label: `4a` `Recording chip — appears only when the menu bar is hidden (fullscreen); hover reveals Stop`;
`data-screen-label="4a Recording chip"`.

### Simulated context (do not implement)

| element | property | design value | note |
|---|---|---|---|
| artboard | width / corner radius | `560px` / `12px` | simulated fullscreen app surface |
| artboard | background | `#101014` | simulation only |
| artboard | shadow | `0 12px 32px rgba(0,0,0,.25)` | simulation only |
| artboard | padding / overflow | `0 0 18px` / `hidden` | simulation only |
| artboard glow overlay | background | `linear-gradient(160deg,rgba(84,98,140,.35),rgba(30,30,36,0) 55%)` | simulated fullscreen content, `position:absolute; inset:0` |
| context label | text | `FULLSCREEN APP · MENU BAR HIDDEN` | annotation, not app UI |
| context label | font / letter-spacing / color | `500 9px` SF Mono / `.08em` / `rgba(255,255,255,.4)` | |
| context label row | layout / padding | `flex; align-items:center; justify-content:space-between` / `14px 18px 0` | |
| specimen row | layout / gap / padding | `flex; justify-content:flex-end` / `14px` / `12px 18px 0` | two specimens, right-aligned |
| specimen column | layout / gap | `flex; flex-direction:column; align-items:center` / `8px` | chip over caption |
| specimen caption 1 | text | `RESTING` | annotation |
| specimen caption 2 | text | `ON HOVER` | annotation |
| specimen caption | font / color | `400 9.5px` SF Mono / `rgba(255,255,255,.35)` | |

### Chip — resting state

| element | property | design value | note |
|---|---|---|---|
| chip | layout / gap | `inline-flex; align-items:center` / `6px` | |
| chip | height | `24px` | |
| chip | padding | `0 10px` | symmetric when Stop is hidden |
| chip | corner radius | `12px` | full pill (height ÷ 2) |
| chip | background | `rgba(30,30,34,.85)` + `backdrop-filter: blur(20px)` | `NSVisualEffectView` `.hudWindow` |
| chip | border | `0.5px solid rgba(255,255,255,.16)` | hairline |
| chip | shadow | `0 4px 14px rgba(0,0,0,.4)` | |
| rec dot | size / radius | `7 × 7 px` / `50%` | same size as the status-item dot |
| rec dot | fill | `#ff453a` | `NSColor.systemRed` (dark) |
| rec dot | animation | `recpulse 1.6s ease-in-out infinite` | opacity 100%→35%; never hidden while capturing |
| elapsed time | font | `500 11px` SF Mono (`ui-monospace,'SF Mono',Menlo,monospace`) | `0.5px` smaller than the menu-bar capsule's `11.5px` |
| elapsed time | color | `rgba(255,255,255,.9)` | menu-bar capsule uses `.95` |
| elapsed time | numerals | `font-variant-numeric: tabular-nums` | |
| elapsed time | text | `24:16` | mm:ss |

### Chip — hover state

| element | property | design value | note |
|---|---|---|---|
| chip | layout / gap | `inline-flex; align-items:center` / `8px` | gap widens from `6px` |
| chip | height | `24px` | unchanged |
| chip | padding | `0 4px 0 10px` | right padding tightens for the Stop pill |
| chip | corner radius | `12px` | |
| chip | background | `rgba(30,30,34,.92)` + `backdrop-filter: blur(20px)` | opacity `.85 → .92` on hover |
| chip | border | `0.5px solid rgba(255,255,255,.2)` | `.16 → .2` on hover |
| chip | shadow | `0 4px 14px rgba(0,0,0,.45)` | `.4 → .45` on hover |
| rec dot | size / fill / animation | `7 × 7 px` / `#ff453a` / `recpulse 1.6s ease-in-out infinite` | unchanged |
| elapsed time | font / color / text | `500 11px` SF Mono, tabular / `rgba(255,255,255,.9)` / `24:16` | unchanged |
| Stop pill | text | `Stop` | |
| Stop pill | layout / height | `inline-flex; align-items:center` / `18px` | |
| Stop pill | padding | `0 9px` | |
| Stop pill | corner radius | `9px` | full pill (height ÷ 2) |
| Stop pill | background | `rgba(255,69,58,.22)` | systemRed @ 22% — note: scratchpad Stop uses 16% |
| Stop pill | hover background | `rgba(255,69,58,.32)` | systemRed @ 32% — scratchpad Stop hover is 26% |
| Stop pill | font | `500 11px` SF Pro | scratchpad Stop is `500 12px` |
| Stop pill | text color | `#ff8a82` | lighter than the scratchpad Stop label `#ff6961` |
| Stop pill | visibility | revealed on chip hover only | resting chip shows dot + time only |

### Behavior contract (prose block on the artboard)

| element | property | design value | note |
|---|---|---|---|
| annotation block | margin / padding | `16px 18px 0` / `10px 12px` | annotation styling, not app UI |
| annotation block | corner radius / background | `8px` / `rgba(255,255,255,.05)` | |
| annotation block | border | `0.5px solid rgba(255,255,255,.08)` | |
| annotation block | font / color | `400 11.5px / 1.6` SF Pro / `rgba(255,255,255,.6)` | emphasis span at `rgba(255,255,255,.85)` |
| window type | kind | small always-on-top **non-activating** window | `.nonactivatingPanel`, floating level |
| window position | placement | top-right corner of the screen | |
| visibility | condition | shown `only while capturing and the status item is off-screen` | emphasised span in the source |
| visibility | trigger cases | fullscreen space; menu bar auto-hidden | |
| hit testing | rule | `Ignores clicks except the Stop pill` | click-through everywhere else |
| dragging | rule | `draggable along the top edge` | horizontal reposition only |
| idle fade | timing / target | after `4 s` idle → `60%` opacity | |
| idle fade | floor | `never fully hides` | |
| appear / dismiss | duration | `180 ms` fade — same as the scratchpad summon | |
| rationale | text | `Closes the consent gap: the indicator — and a stop affordance — now follow the mic everywhere.` | design intent |

---

## HTML vs README discrepancies — sections 3 and 4

`design/README.md` predates turns 3 and 4. Recorded, not reconciled.

| topic | design HTML | `design/README.md` | note |
|---|---|---|---|
| fullscreen indicator | 4a specifies a recording chip window (position, hit-testing, drag, idle fade, 180 ms fade) | no mention of fullscreen, the chip, or a second indicator surface | README Screens list stops at 4. Settings window |
| navigation model | 3a/3b define five journeys, home node, and the reachability table | no journey/reachability content | |
| Quit | 3b: `Quit while recording asks to stop first — the only confirm in the app besides Delete.` | menu item `7. Quit — ⌘Q`, no confirm described | |
| Retry Fusion entry points | J4: reachable from the menu **and** `also in History` | README mentions `Retry Fusion` only as a menu item added on failure | |
| Settings apply model | J5 / 3b: `changes apply live`, `no Save/Cancel` | not stated | |
| History Delete | 3b: `Delete confirms first` | not stated | |
| Scratchpad Stop styling | 4a Stop pill: `500 11px`, `#ff8a82`, fill 22% / hover 32% | README Stop: 12 pt medium, `#FF6961`, fill 16% / hover 26% | two distinct Stop affordances, not a conflict in the HTML |
| file inventory | document contains turns 1, 2, 3, 4 | `## Files` lists only "Turn 1 (bottom)" and "Turn 2 (top)" | README not updated |
| assets | 4a/3a add `⌂`, `⟶`, `⟲`, `⚠`, `✓` glyphs and an outline home marker | `## Assets` says "None — all glyphs are simple shapes" and lists 4 SF Symbols | |

---

## Color → native equivalent map [README]

| hex / rgba | native equivalent | used by |
|---|---|---|
| `#0a82ff` | system accent color (`NSColor.controlAccentColor`) | caret, menu highlight, Start Meeting button |
| `#2b93ff` | accent hover | Start Meeting hover (2a) |
| `#ff453a` | `NSColor.systemRed` (dark) | rec dot, Stop fill base |
| `#ff3b30` | `NSColor.systemRed` (light) | rec dot (1c) |
| `#ff6961` | systemRed-derived text on dark | Stop button label |
| `#34c759` / `#30d158` | `NSColor.systemGreen` | Launch at Login switch / done checkmark |
| `rgba(255,204,0,…)` | `NSColor.systemYellow` | `recovered` tag fill, validator card fill |
| `#e0483e` | failure text token | `failed` meta, `Delete` button |
| `rgba(30,30,33,.9)` + blur 40 | `NSVisualEffectView` `.hudWindow` | scratchpad dark HUD |
| `rgba(40,40,44,.78)` + blur 30 | native `NSMenu` material | menu panel |
| `rgba(30,30,34,.55)` + blur 20 | macOS menu bar (OS-owned) | simulated strip |
| `#f5f4f2` | `NSColor.windowBackgroundColor` | Settings window |
| `#f2f1ef` / `rgba(242,241,239,.96)` | source-list / `.sidebar` material | History sidebar |
| `#1d1d1f` | `NSColor.labelColor` | primary text on light |
| `#333` | `NSColor.textColor` (body) | notes body |
| `rgba(0,0,0,.45)` / `rgba(0,0,0,.5)` | `NSColor.secondaryLabelColor` | captions, meta |
| `-apple-system` | SF Pro via `NSFont.systemFont` | all UI text |
| `ui-monospace,'SF Mono',Menlo` | `NSFont.monospacedSystemFont`, tabular figures | elapsed time, masked API key |
| `#ff5f57` / `#febc2e` / `#28c840` | OS window controls | drawn by `NSWindow`, not the app |
| `#2e2e33` | diagram node fill (documentation only) | 3a menu-bar / dark nodes — not app UI |
| `#0b6329` | dark green on `systemGreen` @16% | 3a `✓ Notes ready · 4 s` node label |
| `rgba(48,209,88,.16)` | `NSColor.systemGreen` @ 16% | 3a success node fill |
| `rgba(48,209,88,.55)` | `NSColor.systemGreen` @ 55% | 3a home-node outline |
| `#8a4a00` | dark amber on `systemOrange` @16% | 3a `⚠ Menu bar · failed` node label |
| `rgba(255,159,10,.16)` | `NSColor.systemOrange` @ 16% | 3a failure node fill |
| `#ff8a82` | systemRed-derived text on dark (lighter than `#ff6961`) | 4a chip Stop pill label |
| `rgba(255,69,58,.22)` / `rgba(255,69,58,.32)` | `NSColor.systemRed` @ 22% / 32% | 4a Stop pill fill / hover |
| `rgba(30,30,34,.85)` / `rgba(30,30,34,.92)` + blur 20 | `NSVisualEffectView` `.hudWindow` | 4a chip resting / hover material |
| `#101014` + `rgba(84,98,140,.35)` gradient | — | simulated fullscreen app backdrop (4a) — do not draw |

---

## Approved deviations from this spec

Deliberate divergences, approved by the owner on 2026-08-19 after dogfooding. They are recorded
here so a future reader does not "correct" the implementation back to the artboards. Each is also
commented at its implementation site.

| # | spec section | spec says | implementation does | why |
|---|---|---|---|---|
| D1 | §4a behavior contract | Recording chip `Ignores clicks except the Stop pill` | A click on the chip body (not the Stop pill, not a drag) shows/fronts the scratchpad panel | The chip was the only always-visible surface while recording, so leaving it inert stranded the user: they could see recording was live but still had no route to the notes. Granola's floating recording indicator resolves the same problem the same way — draggable, shows state, click returns you to the note. Stop remains on the hover-revealed pill per spec. |
| D2 | §3a journey J1 | `Menu bar · idle → Start Meeting → Recording → ⌥⌘N → Scratchpad` — the panel is summoned manually after starting | Entering the recording state shows the scratchpad automatically, from every start path, idempotently | `coordinator.start()` produced no visible surface at all. With the menu bar auto-hidden (fullscreen app), starting a meeting gave zero feedback — the reported failure was "the app never came into focus when I clicked start recording, and then I could never find the scratchpad". J2 is unaffected because the show is idempotent when the panel is already visible. |

Constraint both deviations inherit: neither may activate the app or take focus from the meeting —
the `.nonactivatingPanel` posture (SPEC §5) is load-bearing and is not open to trade.

### Not adopted (roadmap)

| item | note |
|---|---|
| Meeting auto-detection | Granola starts from a calendar reminder ~1 min before a scheduled meeting, and offers to start on detected microphone use for unscheduled calls — which removes the "click Start and wonder if it worked" moment entirely rather than compensating for it. Owner's call: roadmap, not now. |
