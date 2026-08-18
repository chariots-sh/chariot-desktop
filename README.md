# Chariot Desktop

Implementation of the sandboxed agent system described in
[sandboxed-agent-system-design.md](sandboxed-agent-system-design.md): a native
macOS app that runs **OpenAI Codex CLI** inside a disposable Linux VM
(`Virtualization.framework`), plus an iPhone app that pairs via QR code and
drives the agent through end-to-end-encrypted messages **over Tailscale**.

Current state:

- The in-VM agent is real Codex (`codex exec --json` per turn, session resume
  per conversation). Sign-in uses Codex's ChatGPT browser login, brokered per
  design §3.1: the guest initiates, the Mac opens the browser, and the
  `localhost:1455` OAuth callback is tunneled into the guest over vsock. The
  session is sandbox-local (credential level 3): survives Stop/Restart,
  erased by Reset.
- Transport is **Tailscale**: the Mac app bundles `agent-tailnet`, an embedded
  `tsnet` node (one per installation, hostname `agentbox-<suffix>`), exposing
  a single HTTPS/WSS endpoint on tailnet TCP 443. The phone — whose VPN is the
  **official Tailscale iOS app** — holds one persistent WebSocket and resumes
  on foregrounding/network changes. No developer-operated relay, signaling,
  TURN, or mailbox service exists; CloudKit and WebRTC are gone.
  See [docs/tailscale.md](docs/tailscale.md).
- The same transport service also listens on loopback, which is what the
  dev/E2E harness (`chariotd`, simulator) connects to directly with
  `CHARIOT_TAILSCALE=0` — same protocol, no tailnet required.
- **Agent packs (Guardian on Chariot, Milestone 1)**: drop a pack folder into
  the packs directory → create a dedicated Codex VM per agent, populated from
  the pack's markdown/skills/scripts. Multiple agents run concurrently in
  separate VMs; pairing is per agent. See [Agent packs](#agent-packs) below.

## What's here

| Component | Path | Role |
|---|---|---|
| `AgentLinkKit` | `AgentLinkKit/` | Shared Swift package: protocol models, QR v2 payload validation, Ed25519/X25519 envelope crypto, WebSocket frame protocol + session auth, replay protection, device credentials. 23 unit tests. |
| `agent-tailnet` | `agent-tailnet/` | Bundled Go helper: persistent `tsnet` node, NDJSON control protocol over stdio, TLS (Tailscale-issued or pinned self-signed), tailnet→loopback proxy. |
| `ChariotCore` | `ChariotMac/Sources/ChariotCore/` | VM supervisor (`SandboxBackend` over Virtualization.framework), vsock bridge client, transport service (HTTP + WebSocket), tailnet supervisor, pairing/session hub, developer access (SSH over virtio tunnel). Unit/integration tests in `ChariotMac/Tests`. |
| `chariotd` | `ChariotMac/Sources/chariotd/` | Headless daemon used by the E2E harness. |
| Chariot Desktop.app | `ChariotMac/Sources/ChariotDesktopApp/` | SwiftUI app: sandbox lifecycle, conversation, Tailscale panel (sign-in/reauth/disconnect/reset), QR pairing sheet with device approval, revocation, developer access. |
| ChariotMobile.app | `ChariotMobile/` | iPhone app: Welcome/Scanner/Conversation/Connection screens, persistent WSS with backoff+jitter reconnect, durable outbox, revocation handling. |
| Guest assets | `guest/` | `bridge.py` (vsock agent bridge + SSH tunnel + `file.put` pack installer) and the cloud-init `user-data` template. |
| Sample packs | `packs/` | `guardian.pack` (health companion) and `scribe.pack` (note-taker): pack format v1 examples with personas, seeds, and tools. |
| Scripts | `scripts/` | Build/run/E2E helpers. |
| Docs | `docs/tailscale.md` | Tailnet onboarding, HTTPS, Grants policy examples, key expiry, troubleshooting. |
| Docs | `docs/distribution.md` | Developer ID signing, notarization, DMG packaging, Sparkle auto-update, guest-image mirroring. |

## Requirements

- Apple silicon Mac, macOS 14+ (developed on 26.x), Xcode toolchain, Go 1.22+
  (for the bundled `agent-tailnet` helper)
- ~10 GB disk for the guest image and instance disks
- A [Tailscale](https://tailscale.com) account (free for personal use); the
  official Tailscale app on the iPhone
- The Debian ARM64 cloud image. Released builds download it on first run; for a
  checkout, the E2E script fetches it to
  `guest-images/debian-12-genericcloud-arm64.raw`, or:
  ```bash
  curl -L -o guest-images/debian-12-genericcloud-arm64.tar.xz \
    https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-arm64.tar.xz
  tar -xJf guest-images/debian-12-genericcloud-arm64.tar.xz -C guest-images
  ```
  (198 MB compressed rather than 3 GB for the raw file; it expands to the same
  sparse image.)

## Quick start (GUI)

```bash
scripts/build-app.sh        # builds build/Chariot Desktop.app (incl. agent-tailnet, ad-hoc signed)
scripts/run-desktop.sh      # launches it with defaults for this checkout
```

This is the development build: ad-hoc signed, with the updater inert. For a
binary that can be published on the web, `scripts/release-app.sh` produces a DMG
with Sparkle auto-update wired up — Developer ID signed and notarized when a
certificate is available, ad-hoc otherwise (which costs users a one-time
approval in System Settings on first launch). See
[docs/distribution.md](docs/distribution.md).

On first launch without a base image, the app shows a setup screen and downloads
the guest image itself; `CHARIOT_BASE_IMAGE` skips that when you already have
one (which `scripts/run-desktop.sh` sets for this checkout).

In the app: **Tailscale → Sign in to Tailscale** authenticates the embedded
node (one browser login; the identity persists). The sidebar lists your
agents — **New Agent** creates one from a pack (see [Agent packs](#agent-packs));
each agent's page has **Start** (first boot ~40 s while cloud-init provisions
the bridge), a per-agent chat (prefix a message with `!` to run a shell
command inside that agent's guest), **Show pairing QR**, Codex sign-in,
developer access, and **Reset**. Approval of pairing requests is interactive
in the GUI.

iPhone: install the official Tailscale app, join the same tailnet, then scan
the QR with ChariotMobile. Mac and phone restarts don't require rescanning.

iPhone app (simulator, loopback dev mode):

```bash
scripts/build-ios.sh
xcrun simctl install <booted-udid> build/ChariotMobile.app
```

The simulator has no camera and no tailnet: run the Mac side with
`CHARIOT_TAILSCALE=0` so QR payloads carry the loopback service URL, then use
**Copy payload** in the Mac pairing sheet and paste it into the phone's
scanner screen. On a real device the same screen scans the QR live via
`DataScannerViewController`.

## Agent packs

A **pack** is a folder of content — no code runs on the Mac — that defines an
agent: persona markdown, skills, and tool scripts that run *inside* the VM
(no new capability: Codex already runs an unsandboxed shell there). Packs
live in `<data-dir>/packs/`, one folder each (see [`packs/`](packs/) for the
two samples):

```
guardian.pack/
  pack.json          { id, name, version, vm { cpus, memoryMB, diskGB },
                       workspace: [ { src, dest, seedOnly? } ] }
  AGENTS.md          persona/instructions → /workspace/AGENTS.md
  SOUL.md            voice → /workspace/SOUL.md
  MEMORY.seed.md     seedOnly → /workspace/MEMORY.md (written once; the agent
                     owns it afterwards — never overwritten on re-populate)
  skills/…  tools/…  directories are pushed recursively
```

- **Create** an agent from a pack (GUI sidebar → New Agent, or
  `POST /admin/agents`): it gets a fresh **instance UUID** — the durable
  identity and routing key — and its own APFS-cloned VM sized per `vm{}`.
  Pack id/name are cosmetic labels; nothing durable binds to them.
- **Populate**: the hub pushes workspace files over the bridge's `file.put`
  op (path-restricted to /workspace, atomic) on first boot and re-pushes
  edited files before every turn — edit `guardian.pack/AGENTS.md` and the
  next turn sees it, no rebuild. `Reset` re-clones the disk and replays the
  whole workspace, re-seeding MEMORY.md.
- **Pairing is per agent**: each agent is its own pairing endpoint (the QR
  carries its instance UUID) with its own device registry and epoch. A phone
  paired to guardian is, to scribe, indistinguishable from an unpaired one.
  The credential IS the grant — there is no hub-wide agent ACL.
- **Codex sign-in is per VM** (auth lives in each guest, erased by that
  agent's Reset); one brokered browser dance per agent.
- **Phone data uploads**: a paired device can push files into its agent's
  `/workspace` with `file.write` envelopes over the encrypted channel
  (`file.write.result` confirms each write, keyed by request message ID, so
  the phone can order a prompt strictly after its own data). Contents may be
  sent raw or as raw DEFLATE (`"encoding": "deflate"`); the hub inflates
  before the guest sees the file. This is how the A-LIST locomo Guardian
  keeps `/workspace/data/alist-archive.json` fresh before every turn.
- **Chat attachments**: `conversation.send` takes an optional
  `attachments: [String]` — guest paths under `/workspace/data/attachments/`
  the phone uploaded via `file.write` before the message. The hub drops any
  path outside `/workspace` (or containing `..`) and forwards the rest; the
  guest hands image attachments to `codex exec -i` (the model gets pixels)
  and lists every path in the prompt so the agent can open them with tools.
- **Phone tool calls** (reverse RPC): a turn can run a tool on the paired
  phone via the pack's `tools/phone.sh` — the guest bridge forwards the
  request as a `tool.call` envelope (`{request_id, name, arguments, turn_id,
  expires_at}`) to the phone that started the turn, and the phone answers
  with `tool.result` (`{request_id, ok, output, user_visible_summary?,
  error?}`), which flows back into the still-running turn. `expires_at`
  (Unix seconds) lets a phone that receives the call late — envelopes are
  queued durably — drop it instead of executing a stale action; the Mac
  times out at 25s and answers the guest with an error itself, inside the
  script's own 30s ceiling.
- **Replies are deliberate**: a turn's transcript — commands, their output,
  the agent's mid-turn thinking — is `trace`, and stays on the Mac. Only what
  the agent writes through its pack's `tools/reply.sh` is `reply`, and only
  `reply` is forwarded to the phone (a turn that never calls the tool falls
  back to its final message, so an agent can't go silent).
- **Turns continue**: the guest bridge records the Codex thread id per
  conversation under `/var/lib/chariot/threads.json` and resumes it on the
  next turn, so a conversation survives a bridge reconnect or a VM reboot.
- A `data` field in pack.json is reserved for Milestone 2 (phone data
  providers) and ignored by this loader.

## Headless daemon + end-to-end test

```bash
scripts/build-mac.sh
ChariotMac/.build/arm64-apple-macosx/debug/chariotd \
  --data-dir chariot-data \
  --base-image guest-images/debian-12-genericcloud-arm64.raw \
  --guest-resources guest \
  --no-tailscale          # loopback dev mode; omit to run the embedded node
```

`chariotd` serves the transport (pairing + WebSocket) on `127.0.0.1:8787` and
local admin endpoints on `127.0.0.1:8788` (`/admin/pairing`, `/admin/summary`,
`/admin/conversation`, `/admin/revoke`, `/admin/devaccess`, `/admin/tailnet`,
plus the fleet surface: `GET /admin/packs`, `GET|POST /admin/agents`,
per-agent `POST /admin/agents/<uuid>/{vm,pairing,conversation,login}`,
`GET /admin/events` for the hub event buffer, and
`POST /admin/pairing/<id>/approve` to resolve a pairing waiting on the GUI
approval alert — the headless stand-in automated tests use).
The admin surface is never reachable through the tailnet proxy. The GUI and
daemon share the same data dir and ports, so run one at a time
(`pkill -TERM -f chariotd`).

Automated transport E2E (no tailnet or VM needed):

```bash
scripts/e2e-transport.sh    # 16 checks: pairing, WS auth, roundtrip, dedup, offline replay, revocation
```

Automated agent-pack E2E (boots two real VMs — local only):

```bash
scripts/e2e-packs.sh        # Milestone 1 acceptance: 2 concurrent agent VMs, per-pack
                            # workspaces, per-agent pairing, hot pack edits, pack tools,
                            # reset + reseed. Add CHARIOT_E2E_CODEX_AUTH=<auth.json> for
                            # real Codex persona turns.
```

## Tests & CI

```bash
swift test --package-path AgentLinkKit   # protocol, QR validation, envelope crypto, replay
swift test --package-path ChariotMac     # mailbox durability, HTTP/WebSocket transport, paths
```

GitHub Actions ([ci.yml](.github/workflows/ci.yml)) runs on every push to
`main` and every PR: both Swift test suites, the loopback transport E2E
above, an iOS simulator build of ChariotMobile, and `go vet` plus a
universal build of the `agent-tailnet` helper. The VM-backed flows (guest
boot, Codex, developer access) stay local-only — GitHub's macOS runners are
themselves VMs and can't host Virtualization.framework guests.

Developer access (design §1.5): `POST /admin/devaccess {"action":"enable"}`
(or the GUI panel) starts a localhost-only listener forwarded over virtio to
guest sshd, generates the per-instance key/config, and prints the
`ssh -F … chariot-development` command plus copyable Codex instructions.
SSH/SCP remain loopback-only — they are **not** exposed over Tailscale.

## Transport architecture

```
iPhone app ──HTTPS/WSS──▶ tailnet (TCP 443) ──▶ agent-tailnet (tsnet, TLS)
                                                    │ loopback proxy
Official Tailscale iOS app provides the VPN         ▼
                                              transport service (ChariotCore)
                                                    │
                                              agent supervisor → Linux VM
```

- **One node per installation** (`Ephemeral=false`, state in
  `Application Support/ChariotDesktop/tailnet-state`, mode 0700). All sandbox
  instances share it; connections are routed by `instance_id`.
- **No secrets in the QR**: payload v2 carries the MagicDNS service URL (from
  authenticated Tailscale state), the Mac's public keys, an optional TLS pin,
  and a single-use pairing ID + secret. Never auth keys, login URLs, admin
  tokens, or bare 100.x addresses.
- **Tailnet ≠ authorization**: the WebSocket session starts with a
  challenge/response signed by the paired device key; unpaired tailnet peers
  get nothing. All messages remain E2E-encrypted with per-epoch keys.
- **Durability**: outbound mail queues on the Mac until the phone acks;
  the phone keeps a durable outbox until the Mac acks; both sides dedupe by
  device, epoch, and sequence (replay windows). Direct and DERP-relayed
  Tailscale paths behave identically.
- The temporary `tailscale_transport` migration flag is `CHARIOT_TAILSCALE`
  (default on; `0` = loopback dev mode).

## Architecture notes & deviations from the design doc

- **Guest image**: Debian 12 `genericcloud` (raw) booted via EFI, provisioned
  on first boot by cloud-init from a generated seed ISO: creates the `agent`
  user, installs `bridge.py` as a systemd service, locks down sshd. The
  writable disk is an APFS clone of the immutable base image; **Reset**
  re-clones it — exactly the immutable-base + writable-layer model of §1.3.
- **Bridge**: newline-delimited JSON over vsock port 1024 (§1.4). Port 1023
  carries the developer-access SSH tunnel; nothing is ever bound to a LAN
  interface.
- **Transport**: the design doc's CloudKit mailbox + WebRTC direct path was
  replaced wholesale by the Tailscale architecture above. Migration from a
  CloudKit-era install preserves local message history but requires one new
  QR pairing — trust is never transferred through the old transport.
- **Identity storage**: sample persists keys as 0600 JSON files instead of
  Keychain so the ad-hoc-signed daemon and app can share identity without
  keychain ACL prompts. Production: Keychain (§3.1, §13.8).
- **Not implemented**: OAuth broker beyond Codex's brokered login,
  background helper/SMAppService (the helper runs while the app or daemon
  runs; if background receive is needed later, the helper and supervisor move
  into the existing signed background-service architecture with the *same*
  Tailscale identity), artifact import/export UI.
- **Distribution** ships **ad-hoc signed**: a Developer ID Application
  certificate can only be created by the team's Account Holder, so builds are
  not notarized and users must allow the first launch in System Settings →
  Privacy & Security. Auto-update is unaffected, and moving to Developer ID
  later needs only two repository secrets — Sparkle permits the signing identity
  to change while the EdDSA key stays the same. See
  [docs/distribution.md](docs/distribution.md).

## What was verified end to end

1. `AgentLinkKit`: 23/23 unit tests (QR v2 validation incl. expiry/version/
   service-URL/pin rules, pairing key agreement, credential sign/verify,
   envelope round trip, wrong-epoch/expired/third-party rejection, replay
   window, WebSocket challenge-response auth, frame round trip).
2. VM boots under Virtualization.framework; bridge connects over vsock;
   `!commands` execute as `agent` in `/workspace`; guest has NAT internet.
3. Developer access: `ssh -F … chariot-development` through the localhost →
   virtio tunnel, host-key pinned, key-only auth.
4. Pairing (loopback harness): QR v2 payload → session fetch → encrypted
   response → credential issuance → both sides show matching fingerprints;
   QR reuse rejected (atomic single-use pairing ID), expiry enforced.
5. Phone → Mac → VM → phone round trip over the WebSocket with E2E-encrypted
   envelopes, streamed output batched into chunks, acks deleting delivered
   mail on both sides.
6. Durability: messages queued while disconnected are delivered exactly once
   after reconnection (server replay + client replay-window dedup).
7. Revocation: Mac closes the session with a `revoked` frame and advances the
   epoch; phone shows the revoked screen; reconnection is refused;
   re-pairing restores service.
8. Agent packs (`scripts/e2e-packs.sh`, 28 checks against real VMs): two
   packs → two concurrently running VMs with per-pack workspaces and sizing;
   pack tools execute in-guest; files and sessions never cross VMs; per-agent
   pairing admits a device to its own agent and denies it on the other;
   editing a pack lands on the agent's next turn with no rebuild; reset
   re-clones the disk, replays the workspace, and re-seeds MEMORY.md while
   the other agent runs undisturbed.
