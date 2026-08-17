# Distribution

How Chariot Desktop becomes a binary that can be downloaded from a web page and
opened without Gatekeeper complaining, and how installed copies update
themselves afterwards.

Two build paths exist and they are not interchangeable:

| | `scripts/build-app.sh` | `scripts/release-app.sh` |
|---|---|---|
| Build | `swift build`, bundle assembled by hand | `xcodegen` + `xcodebuild archive` |
| Signature | ad-hoc (`-`) | Developer ID Application |
| Notarized | no | yes, app and DMG |
| Updater | inert (no feed key) | Sparkle, live feed |
| Use for | local development | anything a user downloads |

An ad-hoc signed app is fine locally, but once it has been downloaded it
carries a quarantine flag, and Gatekeeper refuses it with "damaged and can't be
opened". Ad-hoc signatures cannot be notarized. Only the release path produces
something publishable.

## One-time setup

### 1. Developer ID Application certificate

An **Apple Development** certificate cannot sign software distributed outside
the App Store. You need a **Developer ID Application** certificate, and for an
organization team only the **Account Holder** can create one.

At <https://developer.apple.com/account/resources/certificates> → "+" →
*Developer ID Application*. Teams are limited to five, and they cannot be
revoked without invalidating already-shipped builds, so keep the `.p12` export
and its password somewhere durable.

Confirm it landed:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

Chariot needs no special entitlement approval: its only entitlement is
`com.apple.security.virtualization`, which is unrestricted. This works because
[VMController.swift](../ChariotMac/Sources/ChariotCore/VMController.swift) uses
`VZNATNetworkDeviceAttachment`. Switching to bridged networking would require
`com.apple.vm.networking`, which needs a separate request to Apple.

### 2. Notarization credentials

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

Set the public key as a repository *variable* named `SPARKLE_PUBLIC_ED_KEY`,
and the exported private key as a *secret* named `SPARKLE_PRIVATE_KEY`.

### 4. GitHub Pages

The appcast is served from the `gh-pages` branch. Enable Pages for the repo
(Settings → Pages → Deploy from branch → `gh-pages` / root). The feed then
lives at `https://chariots-sh.github.io/chariot-desktop/appcast.xml`, which is
the `SPARKLE_FEED_URL` compiled into the app. Changing that URL later strands
every installed copy, so settle it before the first release.

### 5. Repository secrets

| Name | Kind | What |
|---|---|---|
| `DEVELOPER_ID_CERT_P12` | secret | `base64 -i cert.p12` of the exported certificate |
| `DEVELOPER_ID_CERT_PASSWORD` | secret | password used for that export |
| `NOTARY_ISSUER_ID` | secret | App Store Connect issuer UUID |
| `NOTARY_KEY_ID` | secret | API key id |
| `NOTARY_PRIVATE_KEY` | secret | contents of the `.p8` |
| `SPARKLE_PRIVATE_KEY` | secret | exported EdDSA private key |
| `SPARKLE_PUBLIC_ED_KEY` | variable | EdDSA public key |

## Cutting a release

```bash
git tag v0.2.0 && git push origin v0.2.0
```

[release.yml](../.github/workflows/release.yml) then builds, signs, notarizes,
staples, packages the DMG, attaches it to the GitHub release, and publishes the
updated appcast. The DMG is uploaded before the appcast is, so an update check
landing mid-run cannot see a feed entry whose download 404s.

To do it by hand:

```bash
export SPARKLE_PUBLIC_ED_KEY="<public key>"
export NOTARY_PROFILE=chariot
VERSION=0.2.0 scripts/release-app.sh
scripts/make-appcast.sh build/release/ChariotDesktop-0.2.0.dmg
```

`SKIP_NOTARIZE=1` builds and signs without the notarization round trip, which
is useful when testing changes to the pipeline itself.

### What the release script checks

Failures here are cheaper than a bad release, so `release-app.sh` refuses to
continue when:

- no Developer ID Application certificate is present;
- `SPARKLE_PUBLIC_ED_KEY` is unset — shipping with an empty key would leave the
  feed unverifiable;
- `com.apple.security.virtualization` is missing from the signed binary (the app
  would launch and then fail to create any VM);
- the public key did not survive into `Info.plist`;
- `spctl --assess` or `stapler validate` rejects the finished DMG.

## Versioning

`CFBundleShortVersionString` comes from the git tag,`CFBundleVersion` from
`git rev-list --count HEAD`. Sparkle orders releases by `CFBundleVersion`, so it
must increase monotonically — which a commit count does, as long as releases are
cut from `main`.

## Auto-update behaviour

Sparkle checks daily and on demand (Chariot Desktop → Check for Updates…). It
verifies the appcast entry's EdDSA signature and that the downloaded bundle's
Developer ID team matches the running app, independently of each other.

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
  page should say so — an Intel Mac cannot run this.
- **The DMG is not stapled against future revocation.** Notarization tickets can
  be revoked by Apple; stapling only proves the state at signing time.
- **First run needs network** for both the base image and, inside the guest, the
  Codex CLI that cloud-init fetches.
