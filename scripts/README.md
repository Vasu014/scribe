# Scribe scripts

`dev.sh` — contributor one-liner (project generation + package tests + app
build). `release.sh` — the signed-release pipeline (SPEC §6). `ui-gallery.sh`
— UI screenshot harness (below). None is committed-output dependent; all are
safe to run from a fresh clone.

## ui-gallery.sh — UI screenshots for design diffing

```bash
make build                       # DerivedData Debug build the harness shoots
./scripts/ui-gallery.sh          # → /tmp/scribe-ui/<scene>.png (dir overridable: $1)
```

Launches the built app with `-uiGallery YES`, which makes
`ScribeApp.applicationDidFinishLaunching` hand over to `App/UIGallery.swift`
instead of doing the real wiring (no wizard, no Sparkle, no capture engine, no
TCC prompts). The gallery seeds an in-memory store with the fixtures from
`design/README.md` §3, opens every surface as its own window, prints
`GALLERY<TAB>scene<TAB>value` lines, and the script captures each one.
Scenes: `history-notes`, `history-transcript`, `history-empty`, `settings`,
`scratchpad-recording`, `scratchpad-empty`, `scratchpad-no-meeting`,
`wizard-welcome`, `menubar-states`, `menubar-region`.

`value` is a window number (window capture), an `x,y,w,h` region (screen
capture), or `file:<path>` for a scene the app rendered itself.

The menu bar item has two scenes because a status item is not a window:

- `menubar-states` — the app draws the REAL status-item artwork for all five
  states (idle / recording / processing / done / failed) onto a simulated
  design-1a menu bar strip and writes the PNG; the script just collects it.
  Needs no permissions and works with the menu bar hidden.
- `menubar-region` — a `screencapture -R` of the live item: ground truth, but
  only with a visible menu bar (Control Center › "Automatically hide and show
  the menu bar" off) and nothing covering the strip. It is a WARN, not a
  failure, when it comes back blank.

Requirements: the Screen Recording permission for whatever runs the script
(every window scene needs it).

## release.sh env contract

Every secret/identifier comes from the environment — nothing is stored in the
repo. With any required variable missing, the script stops **before building**
and lists what's needed; `--dry-run` prints the full plan with placeholders.

| Variable | Required | Purpose |
|---|---|---|
| `SCRIBE_TEAM_ID` | ✅ | Apple Developer Team ID → `DEVELOPMENT_TEAM` |
| `SCRIBE_SIGNING_IDENTITY` | ✅ | `Developer ID Application: NAME (TEAMID)` → `codesign --sign` |
| `SCRIBE_NOTARY_PROFILE` | ✅ | App Store Connect API or keychain profile name for `xcrun notarytool` |
| `SCRIBE_FEED_URL` | ✅ | Sparkle appcast URL, baked into `SUFeedURL` (Info.plist) at build time |
| `SCRIBE_PUBLIC_ED_KEY` | — | Sparkle Ed25519 public key → `SUPublicEDKey` (signing week) |
| `SCRIBE_BUILD_NUMBER` | — | `CFBundleVersion`; defaults to the git commit count |
| `SCRIBE_OUT_DIR` | — | Output directory; defaults to `dist/` |

Pipeline: xcodegen → Release build (**unsigned**, feed URL baked in) → sign
innermost-first → `codesign --verify --deep --strict` + entitlement audit →
notarize + staple `.app` → `spctl --assess` → `hdiutil` UDZO DMG → sign →
notarize + staple + validate DMG. The DMG is deliberately plain UDZO (no fancy
background/layout) — AJDBZJ/`create-dmg` polish is out of scope for v0.

Three things about that pipeline are load-bearing and easy to undo:

- **Signing order is innermost-first.** Sparkle ships `Autoupdate`,
  `Updater.app` and the two XPC services pre-signed by the Sparkle project
  (ad-hoc, no team, no timestamp), and SPM does not re-sign nested bundles
  inside a binary framework. `release.sh` signs `Installer.xpc` →
  `Downloader.xpc` → `Updater.app` → `Autoupdate` → `Sparkle.framework` →
  `Scribe.app`, per [Sparkle's own
  docs](https://sparkle-project.org/documentation/sandboxing/). Signing a
  container seals what is inside it, so signing outside-in silently
  invalidates the inner signatures and notarization fails with "not signed
  with a valid Developer ID certificate".
- **`--timestamp` on every `codesign`.** Notarization rejects any signature
  without a secure timestamp, including the DMG's. It needs network access.
- **`CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` on the release build.** Xcode
  otherwise merges `com.apple.security.get-task-allow` (the debug entitlement)
  into `App/Scribe.entitlements`, which Apple rejects for distribution. It is
  passed on the `xcodebuild` command line only, so Debug builds, `make build`
  and CI keep the injected entitlement they want.

Every step is a gate. `notarytool submit --wait` **exits 0 even when the
submission comes back `Invalid`**, so `release.sh` parses the JSON `status`
and fails hard on anything but `Accepted`, printing the submission id and the
`xcrun notarytool log …` command to run. Staple and `spctl` failures abort too.

## One-time signing-week setup (human steps)

1. **Developer ID certificate** — Apple Developer Program membership; create a
   *Developer ID Application* certificate in Xcode or developer.apple.com and
   install it in the release machine's keychain.
2. **Notary profile** — store credentials once:
   ```bash
   xcrun notarytool store-credentials SCRIBE_NOTARY_PROFILE \
     --apple-id "you@example.com" --team-id <TEAMID> --password <app-specific-pw>
   ```
   then export `SCRIBE_NOTARY_PROFILE=SCRIBE_NOTARY_PROFILE`.
3. **Sparkle Ed25519 keys** — generate the update-signing keypair (documented
   in `App/dsa_pub.pem`; public key is not secret):
   ```bash
   # After any build that resolved the Sparkle package:
   find ~/Library/Developer/Xcode/DerivedData -name generate_keys -type f
   /path/to/generate_keys          # prints public key, stores private in Keychain
   ```
   Record the public key in `App/dsa_pub.pem` and pass it to releases via
   `SCRIBE_PUBLIC_ED_KEY` (baked into `SUPublicEDKey`). The private key stays
   in the login Keychain and is used by `sign_update`.
4. **Feed hosting** — upload `dist/Scribe-<version>.dmg` somewhere stable and
   serve `distribution/appcast.xml` at the URL passed as `SCRIBE_FEED_URL`
   (the app's `SUFeedURL` must point at the raw appcast URL). Each release
   adds an `<item>` whose `sparkle:edSignature`/`length` come from:
   ```bash
   find ~/Library/Developer/Xcode/DerivedData -name sign_update -type f
   /path/to/sign_update dist/Scribe-<version>.dmg
   ```

## SUFeedURL build-time injection

`SUFeedURL`/`SUPublicEDKey` in `App/Info.plist` are `$(SUFEED_URL)` /
`$(SUPUBLIC_ED_KEY)` build-setting substitutions. `project.yml` ships
placeholder defaults; `release.sh` overrides both on the `xcodebuild` command
line, so the same generated project serves dev builds and real releases.
