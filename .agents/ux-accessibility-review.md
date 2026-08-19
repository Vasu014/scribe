# UX / Journey / Accessibility Review — Scribe interaction layer

Reviewed against `.agents/design-spec.md` §3a/§3b/§4a and SPEC.md §5, working-tree state as of 2026-08-19.
Scope: `App/MenuBarController.swift`, `App/ScratchpadPanelController.swift`, `App/HistoryWindowController.swift`,
`App/SettingsWindowController.swift`, `App/SetupWizardController.swift`, `App/GlobalHotkey.swift`, `App/ScribeApp.swift`,
plus `Packages/MeetingKitCore/Sources/SessionKit/SessionCoordinator.swift` where UI behavior is decided there.

## Verdict

The owner's complaint is accurate and the code explains every symptom. The interaction layer was
polished for how it *looks*, not how it *responds*: the app has **no main menu**, so no keyboard
shortcut works while any Scribe window is frontmost (no ⌘W, no ⌘Q, no ⌘, — and no ⌘V, which makes the
API-key fields effectively type-only); the scratchpad panel is **never made key on summon**, so Esc
physically cannot reach it (and in the no-meeting state it can *never* become key); and the **stop
path emits no state change until capture teardown and the full transcript drain finish**, during
which `SessionCoordinator.elapsed()` returns `0` — which is exactly the owner's "Stop does nothing
+ timer frozen at 00:00" report. Two 3b invariants (fullscreen recording chip, quit-while-recording
confirm) are entirely unimplemented. Reduce Motion is the one accessibility dimension done well;
VoiceOver labeling, keyboard traversal, and contrast on the HUD's muted greys all fail.

Counts: **8 blockers, 10 major, 9 minor** (27 findings).

## Findings (prioritized)

| # | severity | surface | finding | why it matters | suggested fix |
|---|---|---|---|---|---|
| 1 | blocker | Stop flow (panel + menu) | `SessionCoordinator.stop()` sets `phase = .stopping` immediately (`SessionCoordinator.swift:276`) but emits `.stateChanged(.processing)` only **after** `engine.stop()` + `pipeline.finish()` + segment finalization complete (`SessionCoordinator.swift:283–306`). During that window `elapsed()` returns `0` because its guard requires `phase == .recording` (`SessionCoordinator.swift:396–401`), while the panel/menu still render the recording face. The panel's 1 s timer (`ScratchpadPanelController.swift:804–806`) and the menu capsule (`MenuBarController.swift:450`) therefore display a frozen `00:00` with a pulsing red dot, and Stop *appears* to do nothing. If the drain hangs or is slow (WhisperKit flush after a long meeting), this state is indefinite. This is the owner's exact bug report. | Stop looks broken; user cannot tell recording ended; consent posture lies (red dot pulses after capture stopped). | Emit `.stateChanged(.processing)` (or a new `.stopping`) *synchronously* at the top of `stop()`; make `elapsed()` return the last wall-clock value (include `.stopping` in the guard, as `nowOffset()` at `SessionCoordinator.swift:387` already does); surface the drain with the spinner per design 2c. |
| 2 | blocker | Scratchpad panel | Esc is unreachable. `HUDPanel.performKeyEquivalent` (`ScratchpadPanelController.swift:23–31`) only sees key events when the panel is the key window of an app receiving key events. Summon does `orderFrontRegardless()` and never `makeKey` (`show()`, `ScratchpadPanelController.swift:610–626`), and `becomesKeyOnlyIfNeeded = true` (`:537`) means the panel becomes key **only** when the user clicks a view whose `needsPanelToBecomeKey` is true — i.e. the `NSTextView` body. So: after ⌥⌘N, Esc goes to the meeting app; the panel gets it only after a mouse click into the text body. In the **no-meeting state the text view is hidden** (`scrollView.isHidden = !recording`, `:739`) and no other subview needs key, so that face can **never** become key — Esc can never dismiss it, ever. | The design's "way back home" for the panel (3b: "Esc or ⌥⌘N again") is half dead; the owner hit this immediately. | On hotkey summon call `panel.makeKey()` (a `.nonactivatingPanel` can be key without activating the app — Spotlight pattern; SPEC's "never steals key focus from the meeting app" is still honored). Also focus the body text view on summon while recording. |
| 3 | blocker | Scratchpad panel | Keyboard input after summon lands in the **meeting app**, not the scratchpad. Because the panel is never made key (finding 2), the J1/J2 flow "⌥⌘N → jot a fragment" actually types into whatever app was frontmost — plausibly the meeting's chat box. The user must click the body with the mouse before any keystroke reaches Scribe. There is no keyboard path whatsoever to the body or to Stop. | The core product loop (hotkey → type a fragment) does not work hands-on-keyboard; worst case leaks half-typed notes into the meeting chat. | Same fix as 2 (`makeKey` + `makeFirstResponder(bodyTextView)` on summon). |
| 4 | blocker | App-wide keyboard | `NSApp.mainMenu` is never set (`ScribeApp.swift:245–251` builds no menu; grep: no `mainMenu` anywhere in `App/`). Consequences while any Scribe window (Settings, History, wizard, eval sheet) is key: **⌘W does not close** (3b table and J3/J5 explicitly promise ⌘W), **⌘Q does not quit**, **⌘, does nothing**, and there is **no Edit menu**, so **⌘V/⌘C/⌘X/⌘A/⌘Z are all dead** — the API key cannot be pasted into `SettingsWindowController.secureField` (`:311`) or the wizard's `apiKeyField` (`SetupWizardController.swift:674`), transcript text in History cannot be copied, and the scratchpad's `allowsUndo` (`ScratchpadPanelController.swift:401`) is unreachable. The menu-item key equivalents at `MenuBarController.swift:201–227` fire only while the status menu is open. | Breaks the 3b invariant "Every window closes with ⌘W"; makes onboarding (paste an `sk-ant-…` key) nearly impossible; the whole app fails basic macOS keyboard conventions. | Build a minimal main menu at launch (App menu with Quit ⌘Q + Settings ⌘,; Edit menu with the standard cut/copy/paste/select-all/undo selectors; Window menu with Close ⌘W). LSUIElement apps can and should still have a main menu for when they're active. |
| 5 | blocker | Fullscreen recording | Design 4a's recording chip (fullscreen-safe indicator + Stop) is **unimplemented** — no chip window exists anywhere in `App/` (grep for chip: only the Settings key chip). In a fullscreen meeting the menu bar is hidden, the panel may be dismissed, and there is then **no recording indicator and no stop affordance at all** — violating 3b's invariant "the recording indicator cannot be dismissed while capture is live — when fullscreen hides the menu bar, the recording chip (4a) takes over". | Consent/transparency invariant broken in the app's single most common context (fullscreen meeting). | Implement 4a (small `.nonactivatingPanel`, top-right, dot + elapsed + hover Stop) gated on "capturing && menu bar hidden", or at minimum keep the scratchpad panel non-dismissable-to-nothing in fullscreen. |
| 6 | blocker | Quit while recording | 3b invariant "Quit while recording asks to stop first — the only confirm in the app besides Delete" is unimplemented: `ScribeApp` has no `applicationShouldTerminate` (whole file), and Quit is wired straight to `NSApplication.terminate` (`MenuBarController.swift:227`). Quitting mid-recording kills capture with no flush — the session row is left `recording` and resurfaces next launch as a crash-recovery case, and the pending scratchpad fragment (≤1 s debounce) can be lost. | Data loss + invariant violation via a one-click menu item that sits directly under the meeting controls. | Implement `applicationShouldTerminate` → if `coordinator.displayState == .recording`, confirm and run `stop()` (`.terminateLater`) before terminating. |
| 7 | blocker | Scratchpad + History Start | The panel's Start Meeting (`startTapped`, `ScratchpadPanelController.swift:941–949`) and History's empty-state Start (`HistoryWindowController.swift:758–766`) call `coordinator.start()` directly, bypassing the TCC permission guard that only the menu path has (`MenuBarController.swift:287–294`, wired at `ScribeApp.swift:129–136`). With mic/screen permission missing, `start()` throws, the error is **only logged**, and the button silently does nothing — a dead control with zero feedback. | "Buttons that do nothing" — the owner's headline complaint — reproduced on two surfaces; J2 transition 2 fails for any user who skipped the wizard. | Route both through the same guard/callback (`onPermissionsMissing` → wizard step), and surface start failures in UI (alert or inline state), never log-only. |
| 8 | blocker | Scratchpad panel | The HUD buttons likely swallow the **first** click: no view overrides `acceptsFirstMouse` (grep: no overrides in `App/`), the panel is non-key by design, and `NSButton` defaults to refusing first-mouse in a non-key window. Combined with `becomesKeyOnlyIfNeeded` (buttons don't need key), *every* click can be a "first" click, so Stop/Start clicks may be repeatedly eaten depending on OS version. Even when delivered, finding 1 hides any effect. | Second independent mechanism behind "Stop button does nothing"; must be closed to trust the panel at all. | Override `acceptsFirstMouse(for:) -> true` on `HUDButton` (`ScratchpadPanelController.swift:39`); verify with a driven click while another app is active. |
| 9 | major | Menu bar (done state) | `applyDoneVisual` detaches the menu (`statusItem.menu = nil`, `MenuBarController.swift:407`) for the 4 s done transient. During it the entire menu — Quit, Settings, Start Meeting, Open Scratchpad — is unreachable; a click anywhere on the item opens History whether wanted or not; right-click does nothing. | Home surface (3b: "the persistent root") intermittently stops being a menu; a user who clicks to open the menu gets teleported to History. | Keep the menu attached and make only left-click-with-action (or a menu item "Open last notes") the shortcut; or use `sendAction(on:)` with right-click still opening the menu. |
| 10 | major | Menu bar (VoiceOver) | The status item has **no accessibility label in any state**: images are hand-drawn or created with `accessibilityDescription: nil` (`MenuBarController.swift:645`, glyphs at `:534–632`), and no `setAccessibilityLabel`/`title` is ever called (grep: zero accessibility-API calls in `App/` other than reduce-motion checks). A VoiceOver user hears "button" — cannot tell idle from **recording** (elapsed is pixels inside a bitmap) from failed. SPEC §5's "recording indicator always visible — consent posture" simply does not extend to blind users. | Consent claim fails for AT users; primary surface unusable with VoiceOver. | Set `statusItem.button?.setAccessibilityLabel(...)` per state ("Scribe — recording, 24 minutes 16 seconds", "Scribe — notes ready", …) in `applyVisual(for:)`/`refreshRecordingVisual()`, and give the done badge an accessibility action description. |
| 11 | major | Scratchpad (VoiceOver/FKA) | The panel is invisible to keyboard-only and hard for AT users: never key (finding 2), all controls in a borderless non-activating panel, `focusRingType = .none` on the buttons (`ScratchpadPanelController.swift:51`) and body (`:413`) removes the only focus indicator if focus ever lands there, the hand-drawn placeholder is not exposed as `accessibilityPlaceholderValue` (`:120–167`), the red/white state dot (`:257`) is unlabeled, and `savedLabel` toggles via `alphaValue` (`:374`, `:899–930`) so it stays in the a11y tree while invisible. | Whole surface fails Full Keyboard Access and VoiceOver. | Make panel key on summon; restore focus rings or draw a custom one; set `accessibilityPlaceholderValue`; hide `savedLabel` with `isHidden`/`setAccessibilityElement(false)` when faded; label the header group ("Recording, 24:16"). |
| 12 | major | Scratchpad contrast | HUD greys fail WCAG AA on the ~rgb(30,30,33) HUD: placeholder + no-meeting hint white 32 % (`:156`, `:442`) ≈ **2.9:1** at 13 pt; hotkey hint white 35 % (`:377`) ≈ **3.1:1** at 11 pt; "Saved" white 45 % (`:373`) ≈ **4.4:1** at 11 pt (needs 4.5). | Core affordances (the one dismissal hint "⌥⌘N", the only save feedback) are illegible for low-vision users. | Lift to ≥ white 60 % for small text (or use `secondaryLabelColor` resolved under the dark appearance, which the vibrant material adjusts). |
| 13 | major | Setup wizard | No Esc anywhere: Cancel (`SetupWizardController.swift:727`) has no `keyEquivalent = "\u{1b}"` (compare Settings `:330` which does it right), and with no main menu (finding 4) ⌘W is dead too. The only keyboard exit is… none; the only exits are mouse (Cancel button / red traffic light). Also the wizard steals `\r` for Continue (`:734`) so Return can advance a user past a step accidentally while a text field is focused — on the API-key step Return = "Save & Finish". | First surface a new user meets fails the owner's "no way to hit Esc and exit this" test verbatim. | `cancel.keyEquivalent = "\u{1b}"`, or implement `cancelOperation(_:)` on the window; add Close ⌘W via main menu. |
| 14 | major | History keyboard | No initial first responder is set (`buildWindow`, `HistoryWindowController.swift:137–184`), so on open, arrow keys do nothing until the user clicks the table; the four toolbar actions and the segmented control are reachable only with Full Keyboard Access on; there is no ⌘W (finding 4), no ⌘1/⌘2 or `[`/`]` for Notes⇄Transcript, no Delete-key binding on rows. `tableView.focusRingType = .none` (`:215`) also removes the focus indicator that would tell an FKA user the table has focus. | J3 promises "⌘W · non-modal" home; keyboard users can neither navigate nor leave. | Set `window.initialFirstResponder = tableView`; add menu-based ⌘W; consider ⌘⌫ for Delete and a key toggle for the segment; leave the focus ring (or provide selection-based evidence of focus). |
| 15 | major | Settings (VoiceOver) | Controls are unlabeled for AT: `loginSwitch` (`SettingsWindowController.swift:517–522`) reads as bare "switch"; the model/lookback popups (`:452`, `:465`) read only their selected value, not their row titles; the masked-key chip is a plain label with no relationship to the row. Row titles are separate static texts with no `setAccessibilityLabel`/`accessibilityTitleUIElement` link. | VoiceOver users hear a wall of anonymous controls. | `control.setAccessibilityLabel("Launch at Login")` etc. when building each row in `makeRow` (pass the title down). |
| 16 | major | Menu ⌘, hint | `Settings…` shows ⌘, and `Quit` shows ⌘Q (`MenuBarController.swift:212`, `:227`), but status-menu key equivalents fire **only while the menu is open**. Users learn a shortcut that never works (there is no main-menu counterpart, finding 4). Same for ⌥⌘N on the menu item — that one happens to be backed by the Carbon hotkey (`GlobalHotkey.swift:30`), the other two are not. | Advertised shortcuts that silently fail teach users the app is broken. | Back ⌘,/⌘Q with real main-menu items (finding 4 fix covers this). |
| 17 | major | Scratchpad dismissal affordance | The panel has no visible close control at all — no ✕, no button; dismissal is Esc (broken, finding 2) or pressing ⌥⌘N again. The only on-panel hint is the low-contrast "⌥⌘N" text (finding 12). Design 3b does specify Esc/⌥⌘N as the ways home, but with Esc broken the panel is effectively mouse-undismissable. | Owner: "no way to exit this… no buttons". | Fix Esc (finding 2) first; consider a hover-revealed ✕ or making a click outside the panel dismiss it. |
| 18 | major | Stop keyboard path | There is no keyboard way to stop a recording, ever: the panel's Stop is mouse-only (panel buttons can't be focused; Tab inside the body inserts a tab character), the menu's Stop Meeting has no key equivalent (`MenuBarController.swift:194`), and there is no global stop hotkey. | Core loop (J1 transition 3) is mouse-only; accessibility and RSI users excluded. | Add ⏎ or ⌘⏎ = Stop while panel is key; give "Stop Meeting" a key equivalent; consider ⌥⌘N-style global stop or make ⌥⌘. stop. |
| 19 | minor | History (VoiceOver detail) | Action-item checkboxes are `NSTextAttachment` images with no accessibility description (`HistoryWindowController.swift:542`, glyph at `:1390–1400`), so VO reads action items without their checkbox semantics; the fusing row spinner (`:1230–1237`) is unlabeled (though the adjacent "fusing" text mitigates); `window.titleVisibility = .hidden` is fine since `window.title` stays set (`:146–147`). | Mild information loss under VO. | Set `glyph.image?.accessibilityDescription = "unchecked checkbox"` or use attributed-string accessibility. |
| 20 | minor | History empty state | Caption uses `labelColor.withAlphaComponent(0.40)` (`HistoryWindowController.swift:377`) ≈ 2.8:1 in light mode — AA fail; title at 0.65 (`:372`) ≈ 5.9:1 passes. | Low-vision legibility. | Use `secondaryLabelColor` (≈4.6:1) instead of 40 % alpha. |
| 21 | minor | Colour-only state | The menu-bar failure ⚠ is a red glyph with no label (finding 10 covers VO); the History "failed" meta is red **text** (`HistoryWindowController.swift:990–992`) — word + colour, acceptable; the recording dot is colour + elapsed text — acceptable. Net: only the ⚠ badge and the panel's idle-vs-recording dot (white 25 % vs red, `ScratchpadPanelController.swift:718`) rely on colour alone, and the dot is disambiguated by the "No meeting" label. | Verified — mostly OK; fix rides on finding 10. | Label the ⚠ state for AT; no visual change needed. |
| 22 | minor | Modality | 3b says "No modal states anywhere", but exports use `NSSavePanel.runModal()` (`HistoryWindowController.swift:882`), which is app-modal (blocks the status item while open). Sheets (delete confirm `:743`, eval sheet `:833`, error alerts) are correctly window-modal. | Deviation from the invariant; low real-world harm. | Use `panel.beginSheetModal(for: window)`. |
| 23 | minor | Reduce Motion / Transparency / Increase Contrast | Reduce Motion is handled well everywhere (pulse `MenuBarController.swift:451,468`, pop `:492`, summon/dismiss `ScratchpadPanelController.swift:618,646`, saved tick `:897,914`) — but it is read per-event with no observer, so a mid-session toggle only applies to the *next* animation (existing infinite pulse keeps animating: `renderState` isn't re-run on the setting change). Reduce Transparency relies on `NSVisualEffectView` defaults (acceptable). Increase Contrast: hand-drawn hairlines at white 10 %/`separatorColor` and the 0.5 pt card borders don't respond. | Polish-level gaps. | Observe `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` and re-render; optionally bump borders under increase-contrast. |
| 24 | minor | Text size | Every font is a fixed point size (11/12/13/17 pt across all surfaces); nothing tracks the system accessibility text-size or uses text styles. AppKit support is limited, but menu extras and windows ignore even large-text hover. | Low-vision users get no scaling anywhere. | Note as accepted v0 limitation or adopt `NSFont.preferredFont(forTextStyle:)`. |
| 25 | minor | Settings delete key | "Delete" for the API key (`SettingsWindowController.swift:406–413`) acts immediately with no confirm or undo. 3b limits confirms to Quit-recording and session Delete, so this is spec-consistent — but key deletion is destructive and one mis-click from "Edit…". | Mild foot-gun. | Optional: brief confirm or an "Undo" via re-save affordance. |
| 26 | minor | Hotkey remap | ⌥⌘N is hard-coded (`GlobalHotkey.swift:30`); registration failure (conflict with another app) is log-only (`:56–58`) — the user gets a dead hotkey with no UI notice, and the panel is then reachable only via the menu. | Single point of failure for the main entry path. | Surface registration failure (menu-item badge or alert); remap is spec'd "later". |
| 27 | minor | Panel VO identity | The borderless panel does set `panel.title = "Scribe Scratchpad"` (`ScratchpadPanelController.swift:538`) — good — but as a non-activating accessory panel it never appears in any Window menu (none exists) or ⌘\` cycle, so AT users have no discovery path to it other than the hotkey. | Discoverability. | Main-menu Window list (finding 4) + VO label on the panel's content group. |

## Journey walkthrough (design-spec 3a)

### J1 · Record & fuse (happy path)
| transition | verdict | evidence |
|---|---|---|
| Menu bar idle → Start Meeting → Recording | PASS | `MenuBarController.swift:282–304` (guarded start), capsule renders `:447–465` |
| Recording → ⌥⌘N → Scratchpad | PASS (visual) / FAIL (keyboard) | Panel appears (`ScratchpadPanelController.swift:581,610`) but is not key — typing goes to the meeting app (finding 3) |
| Scratchpad → "Stop · or Esc first" → Fusing | **FAIL** | Stop: no state change until drain completes; elapsed shows 00:00 meanwhile (finding 1); first click possibly swallowed (finding 8). Esc: unreachable without a prior click into the body (finding 2) |
| Fusing → auto ~20 s → ✓ Notes ready | PASS | `SessionCoordinator.swift:306` → `.done` via fusion outcome; badge `MenuBarController.swift:406–421` |
| ✓ Notes ready · 4 s → auto → Menu bar idle ⌂ | PASS | `doneRevert` at `MenuBarController.swift:414–432`; but menu is detached during the 4 s (finding 9) |

### J2 · Hotkey first, no meeting running
| transition | verdict | evidence |
|---|---|---|
| Any app → ⌥⌘N → Scratchpad·no meeting | PASS | `GlobalHotkey` → `toggle()` (`ScribeApp.swift:162–165`) |
| → Start Meeting → Scratchpad·recording | **FAIL** (conditionally) | `startTapped` bypasses the permission guard and swallows errors (`ScratchpadPanelController.swift:941–949`, finding 7); with TCC granted it works |
| → "Esc · rec continues" → Menu bar·recording ⌂ | **FAIL** | Esc only works after clicking into the body; in the pre-start no-meeting face the panel can never be key at all (finding 2). ⌥⌘N re-toggle works; recording does continue on dismiss (`dismiss()` `:640`, correct) |

### J3 · Review & export
| transition | verdict | evidence |
|---|---|---|
| Menu bar → History… / click ✓ → History | PASS | `openHistory` `MenuBarController.swift:314`; badge click `:329–333` → `show(sessionId:)` `HistoryWindowController.swift:110` |
| History ⟲ Notes ⇄ Transcript | PASS | segmented `:400–401`, `modeChanged` `:768` |
| → Export / Eval / Delete | PASS | all four actions wired `:688–754`; Delete confirms `:735–754` (invariant honored); eval sheet has ⏎/Esc `:809–811` |
| → "⌘W · non-modal" → Menu bar ⌂ | **FAIL** | No main menu → ⌘W dead (finding 4); close is mouse-only via traffic light |

### J4 · Fusion failure & recovery
| transition | verdict | evidence |
|---|---|---|
| ⚠ Menu bar failed → open menu → Retry Fusion | PASS | ⚠ `MenuBarController.swift:393–395`; menu clears ⚠ on open `:511–519`; Retry item `:197–199`, `:254–255` |
| Retry "also in History" | PASS | `retryTapped` `HistoryWindowController.swift:719–724`, enabled for `processing` rows `:676` |
| → Fusing → ✓ or ⚠ again → Menu bar ⌂ | PASS | `retryFusion` `SessionCoordinator.swift:311–336` |
| "⚠ never blocks Start Meeting" | PASS | start allowed from idle/processing (`SessionCoordinator.swift:208–212`); menu keeps Start enabled `MenuBarController.swift:277` |

### J5 · Settings
| transition | verdict | evidence |
|---|---|---|
| Menu bar → "Settings… · ⌘," → Settings | PASS (menu click) / FAIL (⌘, as a shortcut) | item `MenuBarController.swift:212`; ⌘, fires only while the menu is open, never otherwise (finding 16) |
| "changes apply live · ⌘W" → Menu bar ⌂ | PASS (live-apply) / **FAIL** (⌘W) | every control writes immediately (`SettingsWindowController.swift:481–541`); ⌘W dead (finding 4) |

### 3b invariants
| invariant | verdict |
|---|---|
| No modal states anywhere | MOSTLY PASS (save panels are app-modal — finding 22) |
| Every window closes with ⌘W | **FAIL** (finding 4) |
| Panel dismisses with Esc, no side effects | **FAIL** (finding 2; side-effect-free part is correct) |
| Status item is the persistent root | MOSTLY PASS (menu detached 4 s during done — finding 9) |
| Recording indicator cannot be dismissed while capturing | PASS on a visible menu bar; **FAIL** in fullscreen (finding 5) |
| Fullscreen recording chip (4a) | **UNIMPLEMENTED** (finding 5) |
| Quit while recording asks to stop first | **UNIMPLEMENTED** (finding 6) |
| Exactly two confirms (Quit-recording, Delete) | Delete: PASS; Quit: missing (finding 6) |

## Keyboard-affordance inventory

| affordance | status | evidence |
|---|---|---|
| ⌥⌘N global summon/toggle | EXISTS, works | `GlobalHotkey.swift:30–58`; toggle `ScratchpadPanelController.swift:581` |
| Esc dismiss scratchpad | **BROKEN** | only after a mouse click into the body; impossible in no-meeting face (finding 2) |
| Enter in scratchpad (burst boundary) | EXISTS (after click) | `BodyTextView.doCommand` `ScratchpadPanelController.swift:170–180` |
| ⌘Z undo in scratchpad | **BROKEN** | `allowsUndo` set (`:401`) but no Edit menu to route ⌘Z (finding 4) |
| Keyboard focus of panel / Stop / Start | **MISSING** | panel never key; buttons unfocusable; `focusRingType = .none` `:51` |
| Menu: Start/Stop Meeting shortcut | MISSING | no keyEquivalent (`MenuBarController.swift:194`) |
| Menu: Open Scratchpad ⌥⌘N | EXISTS | menu-open only, but Carbon hotkey covers it globally |
| Menu: Settings… ⌘, | **BROKEN as advertised** | fires only during menu tracking; no main-menu backing (finding 16) |
| Menu: Quit ⌘Q | **BROKEN as advertised** | same; and no confirm while recording (finding 6) |
| ⌘W close (History/Settings/wizard) | **MISSING** | no main menu → no Close item (finding 4); promised by 3b/J3/J5 |
| ⌘V/⌘C/⌘X/⌘A in any text field | **MISSING** | no Edit menu (finding 4) — blocks API-key paste, transcript copy |
| Wizard: Return = Continue / Save & Finish | EXISTS | `SetupWizardController.swift:734` |
| Wizard: Esc = Cancel | **MISSING** | Cancel `:727` has no key equivalent (finding 13) |
| Settings key-edit: Return Save / Esc Cancel | EXISTS | `SettingsWindowController.swift:327,330` (the one surface done right) |
| Eval sheet: Return Save / Esc Cancel | EXISTS | `HistoryWindowController.swift:809–811` |
| History: arrow-key row navigation | PARTIAL | works only after clicking the table; no `initialFirstResponder` (finding 14) |
| History: Delete key on row / segment toggle keys | MISSING | finding 14 |
| Tab traversal | PARTIAL/UNVERIFIED | no `nextKeyView` chains anywhere; relies on auto key-view loop + Full Keyboard Access; focus rings stripped on table (`HistoryWindowController.swift:215`) and HUD (`ScratchpadPanelController.swift:51,413`) |
| Status item via keyboard (Ctrl-F8) | PARTIAL | menu opens normally; during 4 s done state menu is nil (finding 9) |

## Accessibility findings by surface

**Menu bar item** — No accessibility label in any state; elapsed time and "Notes ready" are pixels in
bitmaps (`MenuBarController.swift:534–632`); `tintedSymbol` passes `accessibilityDescription: nil`
(`:645`). Recording state — the consent-critical one — is inaudible to VoiceOver (finding 10). Done
badge is a 4 s, unlabeled, mouse-only target (finding 9). Reduce Motion: handled (static dot, 1 Hz
redraw `:451–469`; pop skipped `:492`).

**Scratchpad panel** — Never key ⇒ unreachable to keyboard/FKA users entirely (findings 2/3/11).
`focusRingType = .none` on `HUDButton` (`:51`) and body (`:413`) removes the only would-be focus
indicator. Hand-drawn placeholder not exposed to AT (`:149–167`). `savedLabel` hidden via alpha, not
`isHidden` (`:374`, `:916–930`) — stale AT node. Contrast failures at white 32/35/45 % (finding 12).
State dot is colour-only but backed by "No meeting"/elapsed text. Reduce Motion: summon/dismiss/pulse/
saved-tick all handled (`:618,646,712,897,914`) — good; no re-render on live setting change (finding 23).

**History window** — `window.title` kept for AT despite hidden title bar (`:146–147`) — good. Row
cells are label-based (VO-readable); "recovered" capsule and "failed" meta carry text, not just
colour. Gaps: no initial focus, no keyboard path to toolbar actions or segment (finding 14);
checkbox attachments unlabeled (finding 19); fusing spinner unlabeled (`:1230`); empty-state caption
2.8:1 (finding 20); table focus ring stripped (`:215`). Validator card: drawn fill behind real text —
VO reads "Validator: …" correctly; drawn card colors are appearance-aware. Design 1d's "black 45 %"
captions were implemented as `secondaryLabelColor` (`:982`, `:1210–1213`) — correct native choice, passes AA.

**Settings window** — Unlabeled `NSSwitch`/popups (finding 15). Edit-in-place flow sets first
responder correctly (`:382`) and has proper ⏎/Esc equivalents (`:327,330`). Cards/hairlines resolve
per appearance (`:589–646`) — good. No ⌘W/⌘,/paste (finding 4).

**Setup wizard** — SF Symbol icons do get `accessibilityDescription` (`SetupWizardController.swift:339`)
— the one labeled imagery in the app. Status conveyed as text + colour (green/red labels with
distinct strings `:396–410`, `:466–487`) — acceptable. Native progress bar — accessible. Gaps: no Esc
(finding 13), Return-driven step advance risk, fixed window with no text scaling, phase captions at
`tertiaryLabelColor` (11 pt, borderline in light mode).

**App-wide** — No main menu (finding 4) is also an accessibility failure: VoiceOver users navigate
apps through the menu bar. No Dynamic-Type/text-size response anywhere (finding 24). Increase
Contrast unhandled (finding 23). Reduce Transparency: delegated to `NSVisualEffectView` defaults —
acceptable.
