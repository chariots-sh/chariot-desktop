# Chariot Desktop

Implementation of the sandboxed agent system described in
[sandboxed-agent-system-design.md](sandboxed-agent-system-design.md): a native
macOS app that runs **OpenAI Codex CLI** inside a disposable Linux VM
(`Virtualization.framework`), plus an iPhone app that pairs via QR code and
drives the agent through end-to-end-encrypted messages over CloudKit.

Current state (the notes below the quick start describe the layered history):

- The in-VM agent is real Codex (`codex exec --json` per turn, session resume
  per conversation). Sign-in uses Codex's ChatGPT browser login, brokered per
  design §3.1: the guest initiates, the Mac opens the browser, and the
  `localhost:1455` OAuth callback is tunneled into the guest over vsock. The
  session is sandbox-local (credential level 3): survives Stop/Restart,
  erased by Reset.
- Transport is real CloudKit (`iCloud.com.protocols.chariot`, private DB custom
  zone) with `CKSyncEngine` change-token fetching on a steady reconcile
  cadence; silent pushes are treated as accelerators only — macOS defers them
  too aggressively to carry latency.
- The localhost HTTP mailbox remains as the dev/E2E-harness transport
  (`chariotd`), and `!command` prompts remain as a raw-shell debug fallback.

## What's here

| Component | Path | Role |
|---|---|---|
| `AgentLinkKit` | `AgentLinkKit/` | Shared Swift package: protocol models, QR payload validation, Ed25519/X25519 envelope crypto, replay protection, device credentials. 18 unit tests. |
| `ChariotCore` | `ChariotMac/Sources/ChariotCore/` | VM supervisor (`SandboxBackend` over Virtualization.framework), vsock bridge client, localhost mailbox server, pairing/session hub, developer access (SSH over virtio tunnel). |
| `chariotd` | `ChariotMac/Sources/chariotd/` | Headless daemon used by the E2E harness. |
| Chariot Desktop.app | `ChariotMac/Sources/ChariotDesktopApp/` | SwiftUI app: sandbox lifecycle, conversation, QR pairing sheet with device approval, paired-device revocation, developer access panel. |
| ChariotMobile.app | `ChariotMobile/` | Sample iPhone app: Welcome/Scanner/Conversation/Connection screens, durable outbox, mailbox polling, revocation handling. |
| Guest assets | `guest/` | `bridge.py` (vsock agent bridge + SSH tunnel) and the cloud-init `user-data` template. |
| Scripts | `scripts/` | Build/run/E2E helpers. |

## Requirements

- Apple silicon Mac, macOS 14+ (developed on 26.x), Xcode toolchain
- ~10 GB disk for the guest image and instance disks
- The Debian ARM64 cloud image (raw): downloaded automatically to
  `guest-images/debian-12-genericcloud-arm64.raw` by the E2E script, or:
  ```bash
  curl -L -o guest-images/debian-12-genericcloud-arm64.raw \
    https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-arm64.raw
  ```

## Quick start (GUI)

```bash
scripts/build-app.sh        # builds build/Chariot Desktop.app (ad-hoc signed)
scripts/run-desktop.sh      # launches it with defaults for this checkout
```

In the app: **Sandbox → Start** boots the VM (first boot ~40 s while cloud-init
provisions the bridge). **Conversation** talks to the agent — prefix a message
with `!` to run a shell command inside the guest. **Devices → Pair new device**
shows the QR code; approval is interactive in the GUI.

iPhone app (simulator):

```bash
scripts/build-ios.sh
xcrun simctl install <booted-udid> build/ChariotMobile.app
```

The simulator has no camera, so use **Copy payload (simulator)** in the Mac
pairing sheet and paste it into the phone's scanner screen. On a real device
the same screen scans the QR live via `DataScannerViewController`.

## Headless daemon + end-to-end test

```bash
scripts/build-mac.sh
ChariotMac/.build/arm64-apple-macosx/debug/chariotd \
  --data-dir chariot-data \
  --base-image guest-images/debian-12-genericcloud-arm64.raw \
  --guest-resources guest
```

`chariotd` exposes the mailbox on `127.0.0.1:8787` plus local admin endpoints
(`/admin/pairing`, `/admin/summary`, `/admin/conversation`, `/admin/revoke`,
`/admin/devaccess`). The GUI and daemon share the same data dir and port, so
run one at a time (`pkill -TERM -f chariotd`).

Developer access (design §1.5): `POST /admin/devaccess {"action":"enable"}`
(or the GUI panel) starts a localhost-only listener forwarded over virtio to
guest sshd, generates the per-instance key/config, and prints the
`ssh -F … chariot-development` command plus copyable Codex instructions.

## Architecture notes & deviations from the design doc

- **Guest image**: Debian 12 `genericcloud` (raw) booted via EFI, provisioned
  on first boot by cloud-init from a generated seed ISO: creates the `agent`
  user, installs `bridge.py` as a systemd service, locks down sshd. The
  writable disk is an APFS clone of the immutable base image; **Reset**
  re-clones it — exactly the immutable-base + writable-layer model of §1.3.
- **Bridge**: newline-delimited JSON over vsock port 1024 (§1.4). Port 1023
  carries the developer-access SSH tunnel; nothing is ever bound to a LAN
  interface.
- **CloudKit stand-in**: this environment has no Apple Developer account, so
  CloudKit/APNs entitlements cannot be provisioned. The encrypted-mailbox
  semantics of §4.6/§13.9 (opaque envelopes, per-recipient fetch after a
  cursor, receipts→deletion, dedup, expiry) are implemented behind a
  localhost-only HTTP server instead. Envelopes are sealed/opened by the same
  `AgentLinkKit` crypto on both ends, so the mailbox only ever sees
  ciphertext — swapping the transport back to CloudKit is a transport-layer
  change only, as the design intends. Phone-side push is replaced by polling.
- **Identity storage**: sample persists keys as 0600 JSON files instead of
  Keychain so the ad-hoc-signed daemon and app can share identity without
  keychain ACL prompts. Production: Keychain (§3.1, §13.8).
- **Not implemented** (per design phasing): WebRTC direct transport (Phase 5),
  OAuth broker (Phase 2's provider integration), background helper/SMAppService,
  artifact import/export UI, notarized distribution.

## What was verified end to end

1. `AgentLinkKit`: 18/18 unit tests (payload validation incl. expiry/replay/
   tamper, pairing key agreement, credential sign/verify, envelope round trip,
   wrong-epoch/expired/third-party rejection, replay window).
2. VM boots under Virtualization.framework; bridge connects over vsock;
   `!commands` execute as `agent` in `/workspace`; guest has NAT internet.
3. Developer access: `ssh -F … chariot-development` through the localhost →
   virtio tunnel, host-key pinned, key-only auth.
4. Pairing: QR payload → rendezvous → encrypted response → credential
   issuance → both sides show matching fingerprints; QR reuse is rejected
   (single-claim rendezvous), expiry enforced.
5. Phone → Mac → VM → phone round trip with E2E-encrypted envelopes, streamed
   output batched into chunks, receipts deleting delivered mail.
6. Durability: message sent while the simulator was killed mid-flight was
   delivered after reboot from the persisted outbox; cursor-based catch-up.
7. Revocation: Mac rejects the device (403) and advances the epoch; phone
   shows the revoked screen; re-pairing restores service and flushes the
   queued outbox.
