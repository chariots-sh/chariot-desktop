# Chariot over Tailscale

Chariot Desktop embeds its own Tailscale node — the `agent-tailnet` helper
bundled inside the app. You do **not** install the Tailscale macOS app. Your
iPhone uses the **official Tailscale iOS app** for its VPN connection; the
Chariot phone app is an ordinary network client and needs no VPN entitlement.

```
iPhone (Tailscale app provides VPN)
   │  HTTPS / WSS over the tailnet, TCP 443
   ▼
agentbox-<suffix>.<tailnet>.ts.net   ← embedded tsnet node in Chariot Desktop
   │  loopback proxy
   ▼
Chariot transport service → agent supervisor → sandboxed Linux VM
```

Tailscale is the private transport; it is **not** the authorization boundary.
Every phone still pairs by QR code, every message is end-to-end encrypted with
the pairing keys, and a device that joins your tailnet but never paired gets
nothing from the service.

## One-time setup

1. **Mac** — open Chariot Desktop → *Tailscale* → **Sign in to Tailscale**.
   The browser opens Tailscale's login; approve the machine
   (`agentbox-<suffix>`). The node identity is stored per-installation in
   `Application Support/ChariotDesktop/tailnet-state` (mode 0700) and is
   reused on every launch — you sign in once.
2. **iPhone** — install the official Tailscale app from the App Store, sign
   in to the *same* tailnet, and toggle the VPN on.
3. **Pair** — Chariot Desktop → *Devices* → **Pair new device**, scan the QR
   with the Chariot phone app. Rescanning is not needed after restarts of
   either device.

### HTTPS (recommended)

If your tailnet has [HTTPS certificates](https://tailscale.com/kb/1153/enabling-https)
enabled (admin console → DNS → HTTPS Certificates), the node serves a
Tailscale-issued certificate for its MagicDNS name and the QR contains no TLS
pin. Without it, Chariot generates a per-installation self-signed certificate
and pins its public-key hash through the QR payload; the phone accepts exactly
that key for that host and nothing else. TLS validation is never disabled
globally.

## Limiting access with Grants

Chariot works with a default (allow-all) tailnet policy. To lock it down, use
[Grants](https://tailscale.com/kb/1324/grants) — deny-by-default once
configured. Example: only your own devices may reach the agent service, and
only on TCP 443:

```jsonc
{
  "grants": [
    {
      "src": ["autogroup:member"],
      "dst": ["autogroup:self"],
      "ip":  ["tcp:443"]
    }
  ]
}
```

If you tag the Mac node (e.g. `tag:agentbox`), scope it further — but only
add a tag whose ownership you have explicitly configured in `tagOwners`;
Chariot never advertises or assumes tags on its own:

```jsonc
{
  "tagOwners": { "tag:agentbox": ["you@example.com"] },
  "grants": [
    {
      "src": ["you@example.com"],
      "dst": ["tag:agentbox"],
      "ip":  ["tcp:443"]
    }
  ]
}
```

Chariot never requests or stores a tailnet admin API credential. The helper
also logs the Tailscale identity (login + node name) of every inbound
connection as defense in depth; application credentials are still verified on
every session.

## Key expiry

Tailscale node keys expire (default 180 days). When the Mac's key expires the
app shows **key expired** and a **Reauthenticate** button — one browser login
brings it back. To avoid this entirely, disable key expiry for the
`agentbox-*` machine in the admin console (available on all plans):
admin console → Machines → ⋯ → *Disable key expiry*.

## Troubleshooting

| Symptom (phone) | Meaning / fix |
|---|---|
| "Can't resolve …" | Tailscale VPN is off on the phone, or the phone is signed into a different tailnet. Open Tailscale and connect. |
| "Reached the network but not the agent service" | The Mac is offline/asleep, its Tailscale login expired, or a Grants policy blocks TCP 443 to the Mac. |
| "The Mac is not answering" | Mac offline or asleep; wake it or check *Tailscale* → status in Chariot Desktop. |
| "TLS identity doesn't match" | The Mac's Tailscale networking was reset since pairing. Pair again with a fresh QR. |
| "This pairing code has expired / was already used" | QR codes are single-use and short-lived. Show a fresh one. |
| "This phone has been revoked" | The Mac revoked this device; re-pair to restore access. |

Direct connections and DERP-relayed connections behave identically at the
application layer — Tailscale picks whichever works; see
[connection types](https://tailscale.com/kb/1257/connection-types).

## Resetting Tailscale networking

*Tailscale → Reset…* deletes the local node identity (the `tailnet-state`
directory). The Mac must authenticate to Tailscale again, and the stale
machine entry can be removed in the admin console. Paired phones keep their
pairing but cannot reconnect until the node is signed in again — and if the
tailnet did not have HTTPS certificates enabled, the self-signed TLS key is
regenerated too, so phones must **re-pair** to pin the new key.

## Plans and pricing

Tailscale's Personal plan is free for personal, noncommercial use (up to
6 users, unlimited devices per user). Commercial deployment of Chariot on a
tailnet needs an appropriate paid Tailscale plan — treat this as a deployment
constraint, not something the app can assume. See
[tailscale.com/pricing](https://tailscale.com/pricing).
