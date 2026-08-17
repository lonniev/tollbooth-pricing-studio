# Courier Bridge — wrist-approval wake architecture

**Status.** Design guidance for implementers. Ratified from field report
guidance escalated as pricing-studio#138 (origin excalibur-mcp#256, context
excalibur-mcp#255). Studio-side wake recognition + device-token retention +
Accept-requires-unlock landed with pricing-studio#139
(`CourierBridgeWake`, `CourierBridgeTokenStore`, `ProofApprovalService.makeCategory`).
The patron-operated Bridge process and independent watchOS app targets remain
to build.

**Problem.** A proof-request DM that arrives while Pricing Studio is
backgrounded or terminated does not reliably surface an Apple Watch
Accept/Reject. The current path depends on an on-device relay listener (or a
foregrounded peer device writing an InboxSignal CloudKit marker). That path
cannot be the always-on answer.

**Goal.** Wake a sleeping iPhone and/or independent watchOS app for Secure
Courier npub-proof consent without putting Operators on the push path and
without relying on a long-lived on-device WebSocket.

**Non-goals.**

- Replacing NIP-59 gift-wrap delivery or the frozen Wrist Approval wire
  contract (`AuthRequest` / `AuthResponse` in DPYCAuthKit).
- Operator- or Authority-hosted push infrastructure.
- Putting claimed identity, scope, npub, or challenge content into the push
  payload (see provenance rules from #243 / Proof-Request Trust Verdict).

---

## 1. Two architectures that look workable and are not

### 1.1 An on-device relay listener will not survive

A backgrounded iPadOS/iOS app receives roughly thirty seconds of execution,
then is suspended and its sockets torn down. No background mode covers
"hold a WebSocket open": audio, location, and BLE qualify; network listening
does not. Apple closed this deliberately when VoIP apps were moved off
persistent sockets onto PushKit.

A suspended app is also terminable — reclaimed under memory pressure, and
once terminated it does not run again until a human relaunches it. A
listener started when the patron opens Studio therefore stops listening
minutes after they leave. That is the reported symptom, not a fix for it.

**Implication.** `RelaySubscriptionManager` / live `DMPollingService`
subscriptions remain correct for *foreground* delivery. They must not be
treated as the always-on wake path. `BGAppRefreshTask` is opportunistic
(~15+ min cadence, OS-scheduled) and is not real-time either.

### 1.2 The iPad cannot reach the Watch

WatchConnectivity pairs a Watch with **one iPhone**. An iPad is not a
participant in that session and has no supported path to a Watch. The chain
"iPad hears the DM → hands to iPhone → iPhone to Watch" has no API behind
its first arrow.

Mirroring iPhone local notifications to a paired Watch remains useful when
the iPhone *does* wake and posts a local banner. It is not a substitute for
waking the Watch when no iPhone is in the path.

---

## 2. The constraint to design around

Waking a sleeping iOS or watchOS device requires **APNs**. There is no
Nostr-native substitute and no arrangement of the patron's own devices that
avoids it. Accept this and design around it rather than attempting to route
around it.

Apple must be in the path. **An Operator must not be.**

---

## 3. Corrected shape — patron-operated Courier Bridge

A small always-on process, patron-operated and co-located with existing
patron infrastructure (e.g. alongside BTCPay on the patron's own host):

1. Holds a long-lived relay subscription for the patron's npubs — a server
   can do what iOS cannot.
2. Holds the patron's own `npub → device token` map. **Operators never see
   tokens.**
3. On an inbound proof-request DM (kind-1059 gift wrap / courier challenge),
   sends a **content-free wake push**: no claimed identity, no scope, no
   npub, no payload. Purely "connect now."
4. The app wakes, connects to the relay, and fetches the real payload
   itself, rendering it per Proof-Request Trust Verdict / #243 — claimed
   identity shown and labeled, never suppressed.

Apple observes timing and nothing else. Correlation risk stays on hardware
the patron controls. This is the same posture as the single-vendor BTCPay
model: the patron runs the infrastructure that knows things about the
patron.

### Residual concerns (stated plainly)

| Concern | Stance |
|---|---|
| **Behavioral log.** Whoever runs the bridge accumulates which Operator asked which patron for what, and when. | Patron-operated keeps that on the patron's metal. An Authority-operated bridge must **not** be the default. |
| **Whoever can push can prompt.** A compromised bridge can deliver perfectly timed approval prompts. | Treat bridge credentials as Operator-grade secrets. |
| **npub disclosure.** | **Not a concern.** npubs are public by design. Earlier drafts treated npub↔token linkage as a leak; that was wrong. The concern is the behavioral log and the push capability, not the identifier. |

### What this displaces (and what it does not)

| Existing piece | Role after Bridge |
|---|---|
| Foreground relay subscriptions | Unchanged — live chat and immediate banners while Studio is open. |
| `InboxSignalService` (CloudKit peer wake) | Remains a *best-effort multi-device* helper when one of the patron's devices is already foregrounded. Not the always-on path; must not block Bridge work. |
| `BGAppRefreshTask` drain | Remains opportunistic catch-up. Not real-time wake. |
| Local `UNNotification` Wrist Approval category | Stays the UX for Approve/Reject once the device has the payload. |
| Operator MCP / Secure Courier tools | Unchanged. Operators still publish challenges; they never learn device tokens. |

---

## 4. Verify before building — watchOS independence

watchOS has supported independent apps holding **their own APNs tokens**
since watchOS 6. If current Apple documentation still confirms this at
implementation time, the bridge can push the Watch **directly**, and the
iPhone leaves the critical path entirely — the cleanest topology, and it
dissolves §1.2 rather than working around it.

**Confirm against current Apple documentation before committing code.**
Background execution and watch-independence rules have moved repeatedly.
Stated here as the preferred direction, not an established fact frozen in
this doc.

PricingStudioCore already declares `.watchOS(.v10)` so shared pure logic
(CourierPayload, ProofApprovalService, this doctrine) can ship into a Watch
target without reimplementation.

---

## 5. Suggested decomposition

This is not a Studio-only bugfix. It is a new component plus thin client
changes:

| # | Piece | Home | Notes |
|---|---|---|---|
| 1 | **Courier Bridge** | New repo (companion infrastructure) | Patron-operated relay watcher + push sender. The substantial piece. Holds npub→token map; sends content-free wakes. |
| 2 | **Wake handling in Studio** | This repo (`tollbooth-pricing-studio`) | Receive content-free push → connect → fetch → classify via `ProofApprovalService` → render per Proof-Request Trust Verdict. |
| 3 | **Independent watchOS app** | This repo (new target) | Own APNs token, actionable Accept/Reject category, `.timeSensitive` interruption level, remaining-validity display. Minimal surface: wake, fetch one DM, render provenance, sign one reply. |

A minimal Nostr Watch app is a reasonable scope for item 3: it makes the
Watch a first-class DPYC approval surface rather than a mirror of the phone.

### Open decision — where signing happens

Accept requires signing with the patron's key. Handling that without a full
app launch means a keychain accessibility class that survives a locked
device — a real security tradeoff that must be decided deliberately.

**Proposed default (locked for guidance):**

- **Reject completes in the background** (safe direction, frictionless).
- **Accept requires unlock** (approval costs a deliberate gesture).

Encode this in client wake-handling and Watch actions; do not silently
grant from a locked device.

---

## 6. Doctrine summary (machine-checkable)

The companion type `CourierBridgeDoctrine` in PricingStudioCore freezes the
non-negotiables so a future implementer (or a regression test) cannot
quietly reverse them:

1. Always-on delivery is **not** an on-device long-lived relay socket.
2. Wake uses **APNs**; there is no Nostr-native device wake.
3. The bridge is **patron-operated**; Operators never hold device tokens.
4. Wake pushes are **content-free** (no identity, scope, npub, or challenge body).
5. Payload fetch + provenance rendering happen **on device** after wake.
6. Preferred Watch topology is an **independent watchOS app** with its own token (verify at build time).
7. **Reject** may complete locked; **Accept** requires unlock.

---

## 7. Origins

- Field report / design guidance: excalibur-mcp#256 (escalated child of the
  guidance transfer).
- Symptom report: excalibur-mcp#255 (Watch Accept/Reject only while Studio
  is foregrounded).
- Related product surface: Wrist Approval wire contract
  (`LocalPackages/DPYCAuthKit/.../WristApproval/`),
  `ProofApprovalService`, `InboxSignalService`, `DMPollingService`.
- Provenance UX: Proof-Request Trust Verdict / excalibur-mcp#243.
