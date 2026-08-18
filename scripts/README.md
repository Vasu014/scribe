# Scribe scripts

`dev.sh` — contributor one-liner (project generation + package tests + app
build). `release.sh` — the signed-release pipeline (SPEC §6). Neither is
committed-output dependent; both are safe to run from a fresh clone.

## release.sh env contract

Every secret/identifier comes from the environment — nothing is stored in the
repo. With any required variable missing, the script stops **before building**
and lists what's needed; `--dry-run` prints the full plan with placeholders.

| Variable | Required | Purpose |
|---|---|---|
| `SCRIBE_TEAM_ID` | ✅ | Apple Developer Team ID → `DEVELOPMENT_TEAM` |
| `SCRIBE_SIGNING_IDENTITY` | ✅ | `Developer ID Application: NAME (TEAMID)` → `CODE_SIGN_IDENTITY` |
| `SCRIBE_NOTARY_PROFILE` | ✅ | App Store Connect API or keychain profile name for `xcrun notarytool` |
| `SCRIBE_FEED_URL` | ✅ | Sparkle appcast URL, baked into `SUFeedURL` (Info.plist) at build time |
| `SCRIBE_PUBLIC_ED_KEY` | — | Sparkle Ed25519 public key → `SUPublicEDKey` (signing week) |
| `SCRIBE_BUILD_NUMBER` | — | `CFBundleVersion`; defaults to the git commit count |
| `SCRIBE_OUT_DIR` | — | Output directory; defaults to `dist/` |

Pipeline: xcodegen → Release build (signed, feed URL baked in) →
`codesign --verify` → notarize + staple `.app` → `hdiutil` UDZO DMG → sign →
notarize + staple DMG. The DMG is deliberately plain UDZO (no fancy
background/layout) — AJDBZJ/`create-dmg` polish is out of scope for v0.

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
