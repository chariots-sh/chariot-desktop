# Distribution

How Chariot Desktop becomes a binary that can be downloaded from a web page and
opened without Gatekeeper complaining, and how installed copies update
themselves afterwards.

## The three build paths

| | `build-app.sh` | `release-app.sh` (ad-hoc) | `release-app.sh` (Developer ID) |
|---|---|---|---|
| Build | `swift build`, hand-assembled | `xcodegen` + `xcodebuild archive` | same |
| Signature | ad-hoc | ad-hoc | Developer ID Application |
| Notarized | no | no | yes, app and DMG |
| First launch | n/a (local) | user must allow it once | double click |
| Updater | inert (no feed key) | Sparkle, live feed | Sparkle, live feed |
| Use for | local development | shipping without a certificate | shipping properly |

`release-app.sh` picks its mode from whether a Developer ID certificate is in
the keychain. `ADHOC=1` forces ad-hoc.

## Shipping ad-hoc

Chariot currently ships ad-hoc, because a **Developer ID Application**
certificate can only be created by a team's Account Holder and we do not have
one yet. What that costs, precisely:

- **The first launch is blocked.** macOS says the app "is damaged and can't be
  opened", which is misleading — it is the generic message for an app Gatekeeper
  cannot verify. The user opens **System Settings → Privacy & Security** and
  clicks **Open Anyway** once. `release-app.sh` puts an `INSTALL.txt` in the DMG
  saying so, and the release workflow puts it in the release notes.
- **`spctl` rejects the DMG.** Expected; the release script prints the real
  verdict rather than asserting success.
- **The sha256 is the only integrity signal.** Publish it next to the download.
  The script prints it.

What it does *not* cost:

- **Auto-update still works.** Sparkle accepts an app-bundle update on either
  matching EdDSA keys *or* a matching code-signing identity — the EdDSA key is
  enough on its own, and Sparkle's own docs say "if no Apple Code Signing
  certificate is available, adhoc signing can be used at minimum". It also
  clears quarantine on what it installs, so the Privacy & Security step is
  **first-install-only**.
- **Moving to Developer ID later is a supported transition.** Sparkle explicitly
  allows the code-signing identity to change as long as the EdDSA key matches,
  so existing ad-hoc installs will update themselves to notarized builds. The
  one thing that must not change is `SPARKLE_PRIVATE_KEY`.

To switch modes later, add the two certificate secrets; nothing else changes.

## One-time setup

### 1. Developer ID Application certificate (optional — skip for ad-hoc)

An **Apple Development** certificate cannot sign software distributed outside
the App Store. You need a **Developer ID Application** certificate, and for an
organization team only the **Account Holder** can create one.

At <https://developer.apple.com/account/resources/certificates> → "+" →
*Developer ID Application*. Teams are limited to five, and they cannot be
revoked without invalidating already-shipped builds, so keep the `.p12` export
and its password somewhere durable.

If you are not the Account Holder, the cleanest handoff avoids sending a private
key around: generate the CSR yourself (Keychain Access → *Certificate Assistant
→ Request a Certificate From a Certificate Authority*, saved to disk), have the
Account Holder upload it and send back the resulting `.cer`, and import that.
Your private key never leaves your machine, and they never handle one.

Confirm it landed:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

Chariot needs no special entitlement approval: its only entitlement is
`com.apple.security.virtualization`, which is unrestricted. This works because
[VMController.swift](../ChariotMac/Sources/ChariotCore/VMController.swift) uses
`VZNATNetworkDeviceAttachment`. Switching to bridged networking would require
`com.apple.vm.networking`, which needs a separate request to Apple.

### 2. Notarization credentials (Developer ID mode only)

Create an App Store Connect API key (Users and Access → Integrations → Keys)
with the *Developer* role, then store it once:

```bash
xcrun notarytool store-credentials chariot --key ~/Downloads/AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-uuid>
```

`chariot` is the profile name the release script expects via `NOTARY_PROFILE`.

### 3. Sparkle signing key

Sparkle signs each update with an EdDSA key that is independent of your Apple
certificate. Generate it once:

```bash
./ChariotMac/.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

The private half goes into your login keychain; the tool prints the public
half. The public key is not secret — it is compiled into the app so it can
verify the feed.

**Losing the private key ends the update path for every installed copy.** Back
it up (`generate_keys -x private-key.txt`) and store it offline. Existing
installs only trust the key baked into the version they are running, so a new
key requires users to reinstall manually.

This matters more while shipping ad-hoc: with no notarization, the EdDSA
signature is the *only* thing standing between a user and a malicious update.
It is also what makes the eventual move to Developer ID painless, since Sparkle
allows the signing identity to change when the key matches.

Set the public key as a repository *variable* named `SPARKLE_PUBLIC_ED_KEY`,
and the exported private key as a *secret* named `SPARKLE_PRIVATE_KEY`. The
scripts pass it to Sparkle on stdin, so it is never written to disk in CI.

The exported key is base64 of the 32-byte ed25519 seed. Sparkle also accepts a
96-byte legacy layout; a 64-byte seed-plus-public-key concatenation is *not* a
valid format and fails with "Failed to decode private and public keys".

### 4. GitHub Pages

The appcast is served from the `gh-pages` branch. Enable Pages for the repo
(Settings → Pages → Deploy from branch → `gh-pages` / root). The feed then
lives at `https://chariots-sh.github.io/chariot-desktop/appcast.xml`, which is
the `SPARKLE_FEED_URL` compiled into the app. Changing that URL later strands
every installed copy, so settle it before the first release.

### 5. Repository secrets

Only the last two are needed to ship ad-hoc. Adding the first five switches the
workflow into Developer ID mode with no other change.

| Name | Kind | What |
|---|---|---|
| `DEVELOPER_ID_CERT_P12` | secret | `base64 -i cert.p12` of the exported certificate |
| `DEVELOPER_ID_CERT_PASSWORD` | secret | password used for that export |
| `NOTARY_ISSUER_ID` | secret | App Store Connect issuer UUID |
| `NOTARY_KEY_ID` | secret | API key id |
| `NOTARY_PRIVATE_KEY` | secret | contents of the `.p8` |
| `SPARKLE_PRIVATE_KEY` | secret | exported EdDSA private key |
| `SPARKLE_PUBLIC_ED_KEY` | variable *or* secret | EdDSA public key |

`DEVELOPER_ID_CERT_P12` is what the workflow branches on: unset means ad-hoc.

The public key is not sensitive — it ships inside the app — so a *variable* is
its natural home, and keeping it visible makes it easy to confirm a build was
signed against the key you think it was. The workflow falls back to a *secret*
of the same name, because an unset `vars.` reference silently becomes an empty
string and the resulting failure does not point at the real cause.

## Cutting a release

```bash
git tag v0.2.0 && git push origin v0.2.0
```

[release.yml](../.github/workflows/release.yml) then builds, signs, packages the
DMG, attaches it to the GitHub release, and publishes the updated appcast —
notarizing and stapling too when a certificate is configured. The DMG is
uploaded before the appcast is, so an update check landing mid-run cannot see a
feed entry whose download 404s.

To do it by hand, ad-hoc:

```bash
export SPARKLE_PUBLIC_ED_KEY="<public key>"
ADHOC=1 VERSION=0.2.0 scripts/release-app.sh
SPARKLE_PRIVATE_KEY="<private key>" VERSION=0.2.0 TAG=v0.2.0 \
  scripts/make-appcast.sh build/release/ChariotDesktop-0.2.0.dmg
```

With a certificate, drop `ADHOC=1` and add `export NOTARY_PROFILE=chariot`.
`SKIP_NOTARIZE=1` then builds and signs without the notarization round trip,
which is worth doing once before a real release to confirm signing works.

### What the release script checks

Failures here are cheaper than a bad release, so `release-app.sh` refuses to
continue when:

- `SPARKLE_PUBLIC_ED_KEY` is unset — with no notarization this is the only
  verification an update gets, so an empty key is never acceptable;
- `com.apple.security.virtualization` is missing from the signed binary (the app
  would launch and then fail to create any VM);
- the public key did not survive into `Info.plist`;
- the bundle is not code signed at all — Sparkle rejects an update that drops
  code signing, so this would break updates for everyone already installed;
- in Developer ID mode, `spctl --assess` or `stapler validate` rejects the DMG.

In ad-hoc mode `spctl` is *expected* to reject the DMG, so the script prints the
real verdict instead of asserting success.

## Versioning

`CFBundleShortVersionString` comes from the git tag,`CFBundleVersion` from
`git rev-list --count HEAD`. Sparkle orders releases by `CFBundleVersion`, so it
must increase monotonically — which a commit count does, as long as releases are
cut from `main`.

## Auto-update behaviour

Sparkle checks daily and on demand (Chariot Desktop → Check for Updates…). For an
app-bundle update it requires *either* a valid EdDSA signature against the key
compiled into the running app, *or* a matching code-signing identity — either one
suffices, and it deliberately allows the signing identity to change so keys and
certificates can be rotated. It always requires that the new bundle be signed
somehow (ad-hoc counts) and that it still carry an EdDSA key.

For ad-hoc builds that means the EdDSA signature is the whole of the
verification, which is why `SPARKLE_PRIVATE_KEY` is the most sensitive thing in
this pipeline.

The one Chariot-specific rule lives in
[UpdaterController](../ChariotMac/Sources/ChariotDesktopApp/UpdaterController.swift):
when an update is ready and agents are running, the relaunch is postponed, the
fleet is stopped cleanly, and only then does the install proceed. Replacing the
bundle underneath a live `Virtualization.framework` VM would kill agents
mid-turn.

Development builds carry no `SUPublicEDKey`, so `UpdaterController.isConfigured`
is false and the updater never starts — a dev build will not try to replace
itself with a released one.

## Guest base image

The app ships without the ~3 GB Debian guest image and downloads it on first run
(198 MB compressed), driven by
[BaseImageInstaller](../ChariotMac/Sources/ChariotCore/BaseImageInstaller.swift).

The image is mirrored as a release asset rather than fetched from Debian
directly. `cloud.debian.org` keeps only about three dated builds and prunes the
rest, so a pinned upstream URL stops resolving within weeks; `latest/` stays up
but changes bytes without notice, which would mean two installs of the same
Chariot version running different guests. The mirror is permanent and the pinned
SHA-256 names exactly one image.

To move to a newer Debian build:

```bash
scripts/mirror-base-image.sh                 # dry run; prints the new values
UPLOAD=1 scripts/mirror-base-image.sh        # publish the asset
```

Then paste the printed `BaseImageRelease.pinned` values into
`BaseImageInstaller.swift` and cut a release. Existing installs keep the image
they have — `status()` reports `.outdated` rather than forcing a re-download,
since an older guest still boots.

For local work, `CHARIOT_BASE_IMAGE` points at an image you already have and
skips the whole flow. `CHARIOT_BASE_IMAGE_URL` plus `CHARIOT_BASE_IMAGE_SHA256`
override the mirror without a rebuild.

## Known limits

- **Apple silicon only.** The guest is ARM64 Linux under
  `Virtualization.framework`; there is no meaningful x86_64 build. The download
  page should say so — an Intel Mac cannot run this. Sparkle infers
  `sparkle:hardwareRequirements` from the shipped slices, so it will not offer
  updates to Intel hardware.
- **Ad-hoc builds need a manual first launch**, and macOS describes them as
  "damaged", which generates support questions. This is the cost of not having a
  Developer ID certificate, and it goes away entirely once one exists.
- **In Developer ID mode, the DMG is not stapled against future revocation.**
  Notarization tickets can be revoked by Apple; stapling only proves the state at
  signing time.
- **First run needs network** for both the base image and, inside the guest, the
  Codex CLI that cloud-init fetches.
