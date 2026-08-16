# Changelog

## [Unreleased]

### Added — Courier Bridge design guidance (wrist-approval wake path)

On-device long-lived relay listeners are not a viable always-on path for
Wrist Approval: iOS suspends background sockets, and an iPad has no
WatchConnectivity path to a Watch. `design/courier-bridge.md` records the
corrected shape — a patron-operated Courier Bridge that holds relay
subscriptions and the patron's own `npub → device token` map, then sends
**content-free** APNs wakes so the device fetches and renders the real
payload itself. Operators never see tokens. Preferred Watch topology is an
independent watchOS app with its own token (confirm against current Apple
docs at implementation time). Proposed signing default: Reject may complete
while locked; Accept requires unlock.

`CourierBridgeDoctrine` in PricingStudioCore freezes the non-negotiables as
machine-checkable predicates so a future change cannot quietly reverse them.

### Changed — the patron account card groups by surface instead of by rules

Statement moves onto the account row beside Top Up and Refresh; it is something
you do *to* a balance, and stranded between two rules it read as its own feature.
The full-width `Divider()`s are gone — on an iPad-wide card they draw a line
across the whole pane and read as a page break rather than a grouping.

Patron Secrets move out of the collapsed *Details & secrets* disclosure and sit
directly under the balance as a card in their own right. They are configuration,
not a detail of how the balance was spent — and a missing key used to render
identically to no key being needed until the disclosure was expanded. The
disclosure keeps only the ledger and is renamed *Ledger detail*.

### Fixed — the Secure Courier now names the mailbox that receives the DM

An Operator delivering its own secrets was told the exchange was with its
**Authority**. The Authority takes no part in a credential exchange; it holds the
Operator's credits, which is a different relationship. `AccountStatementView`
already drew that distinction in a comment on `ownEndpoint`, then passed the
credit-holding service into the two fields that name the credential-management
target. Three of five `CourierParams` fields were already right, so the flow was
mislabelled rather than misrouted — it would have worked, while pointing the
operator at a service with nothing to do with it.

`CourierParams` now carries `mailboxNpub` / `mailboxName`: the courier addresses
whoever *delivers* the secrets, so that is the conversation to open. The card had
computed `effectiveSender` for auth since it was written, then displayed
`operatorNpub` beside it.

### Fixed — Open Messages is always offered

The button was suppressed whenever `senderNpub` was empty — exactly the case where
an operator delivers its own secrets — so that path gave no way to reach the reply
at all. It is now always shown, and points at the mailbox rather than the service.

### Added — a proof request now shows the operator-observed request origin

Paired with tollbooth-dpyc 0.67.0, which signs an `origin` tag (geo · coarse IP ·
claimed client, harvested server-side from the transport) into the attestation.
The trust banner surfaces it as **"Request origin: …"** so a human can judge an
*unsolicited* request by *where it came from*, not only *who signed it* — the
missing datum for the anyone-can-trigger-a-proof-DM gap. Shown only when the
attestation validly verified (observed, tamper-evident; never client
self-report), and omitted best-effort when the transport exposed nothing.

### Changed — trimmed the delivery-key verdict wording

"Operator-attested / your operator identity / Attested by your operator identity…"
was redundant. The green self/known-via-delivery-key verdict now reads
**"Operator-signed"** with a one-line detail: *"Delivered from a one-time key,
not the operator's own npub — trust rests on the signature, not the sender."*

### Fixed — a one-time delivery key is no longer presented as the operator itself

A self-addressed proof DM is delivered from a throwaway "delivery key" (relays
drop self-DMs) and vouched for by the operator's signed attestation. The verdict
collapsed that into "Verified operator", reading as *the sender is the operator*
— but the sender npub is the temporary key, not the operator's own. When the
verified signer differs from the DM's actual sender, the verdict now says
**"Operator-attested"** and states plainly that it was *delivered via a one-time
key — the sender npub is not the operator's own; its authority is the signature,
not the sender*. A direct operator DM (sender == signer) still reads "Verified
operator". The trust level is unchanged (a valid attestation is still trusted);
only the claim about *who sent it* is corrected.

### Fixed — a proof/approval request no longer renders as a bare, un-actionable credential form

A proof-request DM (npub-ownership) parses to a valid courier payload with **zero**
editable fields — so the credential-delivery card rendered an empty form with a
disabled "Fill at Least One Field" button, which read as raw and gave the human
nothing to act on. `CourierPayloadView` now detects the approval case
(`fields.isEmpty` + a challenge) and renders it as an **approval**: the trust
verdict and stated purpose lead, the empty field form is dropped, and the action
becomes a confirm/ignore. For an unverified (red) signer the confirm is
de-emphasized and captioned — ignoring is a first-class outcome. `CourierPayload`
also parses the `Reason:` provenance line for display.

### Added — an unknown signer's *stated purpose* is now shown alongside its claimed identity

Building on show-and-label (below): a proof/credential request whose attestation
carries a signed `reason` tag (tollbooth-dpyc ≥ 0.66.0) now renders that purpose
in the trust banner — "Stated purpose: I'm working on your request XYZ and need
the Operator to do ABC." `ProofProvenance.TrustAssessment` gains a `reason`,
taken from the signature-bound tag (never the relay-mutable plaintext) and shown
only when the attestation validly verified — so it is *what the signer said*,
labelled, never an endorsement. For the unknown-signer red case this pairs the
claimed identity with the "why" a human needs to judge a stranger's ask.

### Changed — an unknown signer's claimed identity is now shown-and-labelled, not hidden

The red "Unknown requester" verdict for a *validly-signed* proof-request DM
whose key is not in your registry no longer suppresses the claim. Because the
signature verified, the asserted identity is cryptographically bound to that
specific key — hiding it is exactly wrong, since the unknown-signer case is
when you most need the claim to catch an impostor asserting a name you
recognise from a key you don't. `ProofProvenance.TrustAssessment` gains a
`claimedIdentity` (distinct from the verified `resolvedIdentity`, still nil on
red), and the trust banner renders it plainly labelled "unverified, not in your
registry." The verdict stays red / do-not-approve, and a *failed* verification
(bad signature / mismatch / absent) still surfaces nothing — there is no bound
claim to trust (issue #105, escalated from lonniev/excalibur-mcp#243).

### Added — a proof-request DM now shows a green/amber/red trust verdict

When a Secure-Courier DM asks you to authorize your identity, the app now
tells you — cryptographically, not on the requester's say-so — whether the
request truly comes from your registered operator. This lands the client half
of the SDK's Operator provenance attestation (tollbooth-dpyc #135).

- **Schnorr verification** (`DPYCAuthKit.verifyEventSignature`) — verifies a
  kind-27235 event's signature and id integrity via `P256K`. A pinned fixture
  test proves a Python-SDK-signed attestation verifies here (cross-language).
- **Provenance trust engine** (`PricingStudioCore.ProofProvenance`) — parses
  the embedded attestation, checks the signature (injected, keeping Core
  crypto-free) and that its bound facts (delivery key, subject, one-time
  challenge) match the DM received, then decides the trust level. Fail-closed:
  a present-but-invalid attestation or an unresolved signer is **red** and
  suppresses any claimed name; an absent attestation is **amber**, never green.
  `CourierPayload` now captures the attestation and the `Delivery key:` line
  and no longer surfaces the attestation as an editable field.
- **Trust banner** (`CourierPayloadView`) — a green/amber/red banner with the
  verified identity (suppressed on red). For a self-proof the verdict uses only
  data on the DM: the attestation signer resolving to the DM's own recipient
  identity yields green; an impostor signing with any other key yields red.
  Community-registry resolution for cross-operator requests is a follow-up.

### Changed — Top Up sheet redesigned as a ticket-kiosk fare picker

The shared `PurchaseCreditsSheet` now buys credits the way you buy a
transit pass at a station kiosk, using SF Symbols and the app's native
card idioms (no hand-drawn artwork):

- **Hero "fare pass" stub** folds the former Beneficiary/Cashier rows
  into a printed ticket header with a dashed perforation tear line. The
  two parties sit side by side — **Benefitting** on the left, **Cashier**
  on the right — each tagged with its actor badge: Operator =
  `server.rack` (orange), Authority = `building.columns` (blue), Patron =
  `person.fill` (green), mirroring `TopologyViewModel`.
- **Fare-card grid** replaces the row of grey amount pills with a 2×2
  grid of tappable ticket tiles (`ticket.fill` + bold denomination).
  Selecting one gives it a tinted fill, accent border, and a
  punched-ticket checkmark.
- **Full-width Custom tile** reveals the number pad on tap;
  `effectiveAmount` keys off the custom-field state so the Top Up button
  and minimum-amount logic stay correct.

Presentation only — the Lightning purchase, payment-check, and
npub-proof exchange flows are untouched. Sat tranches are styled as
stored-value denominations, not time-based passes (100 sats is a
quantity, not a day).

Badges are parameterized (`ActorBadge`) with Patron→Operator defaults,
so the two Patron call sites are unchanged; the Operator/Authority sites
pass their matching pair.

## [1.10.0] — 2026-05-27

### Changed — Reconcile is now UUID-joined against the wheel's canonical inventory

Through-fix of the chronic UUID-derivation pathology that the 1.9.x
series tried to patch. Studio's Reconcile no longer derives UUIDs
locally from tool names. It calls the wheel's new
`list_canonical_identities` tool (added in tollbooth-dpyc 0.38.0),
which returns the canonical `(tool_id, mcp_name, category, intent)`
tuples directly from `rt._tool_registry`. Studio UUID-joins that
inventory against the stored pricing model:

- **Matched by UUID** → preserve the stored row's price and
  multipliers; refresh `toolName`, `category`, `intent` from the
  canonical entry if they've drifted (operator renamed a function,
  changed a category, or edited intent prose).
- **Canonical UUID not in stored** → add as a TBD row using the
  canonical mcp_name and category.
- **Stored UUID not in canonical** → drop (tool was removed in code).

#### What this fixes for good

The Brain MCP's v1.9.20 capability-rename broke Studio's local UUID
derivation because Studio computed `capabilityUUID("get_thought_by_name")`
but the wheel had switched to `capability_uuid("get_knowledge_node_by_name")`.
1.9.4's repair pass made it worse on Reconcile by overwriting the
correct UUIDs with Studio's locally-computed (wrong) ones. Both
problems disappear under the new flow because Studio doesn't compute
any UUID itself — the wheel is the source of truth.

#### Removed (breaking on the ViewModel API)

- `ReconciliationViewModel.orphanTools`
- `ReconciliationViewModel.hasOrphans`
- `ReconciliationViewModel.repairedOrphanCount`
- `ReconciliationViewModel.bareCapability(_:)`
- `ReconciliationViewModel.canonicalToolId(forMCPName:)`
- `ReconciliationViewModel._setOperatorSlug(_:)`
- The orange "Orphan UUIDs" diagnostic block and the orange "Repaired"
  review banner in `ReconciliationSheet.swift` — there is no longer
  any class of orphan that Studio can repair or needs to flag.
- `ReconciliationViewModel`'s private `inferCategory(_:)` heuristics —
  the canonical inventory carries the wheel-side category directly.

#### Changed (signature)

- `MCPService.ToolMismatch`:
  - `newTools: [Tool]` → `newIdentities: [CanonicalIdentity]`
  - `matchedTools: [ToolPrice]` → `matchedPairs: [(stored, canonical)]`
    (kept `matchedTools` as a computed projection for API compat)
- `MCPService.detectToolMismatch` now calls
  `MCPService.fetchCanonicalIdentities(endpointURL:)` and UUID-joins.
  `operatorSlug` parameter is accepted but ignored.
- `PricingViewModel.applyReconciliation` no longer takes
  `orphanIdsToRemove`; staging is purely UUID-keyed.

### Added

- `MCPService.CanonicalIdentity` — `(toolId, mcpName, category, intent)`
  tuple as returned by the wheel.
- `MCPService.fetchCanonicalIdentities(endpointURL:)` — calls the
  wheel's `list_canonical_identities` tool. Throws a clear error if
  the operator is on tollbooth-dpyc 0.37.x or earlier (which doesn't
  expose the tool yet).

### Operator requirement

Operators must update to tollbooth-dpyc **0.38.0** or newer for
Studio 1.10.0's Reconcile to work. Operators on 0.37.x will see an
error from the Reconcile sheet telling them to upgrade.

### Tests

- `ReconciliationUUIDTests.swift` rewritten end-to-end. Old tests for
  `bareCapability`, `canonicalToolId`, and orphan repair are deleted
  (those code paths no longer exist). New tests cover the four
  cases the new flow handles: add-new, drop-stale, refresh-on-drift,
  and noop-when-unchanged.

## [1.9.4] — 2026-05-26

### Fixed — orphan repair never removed the pre-repair row, so Reconcile looped

1.9.3 detected orphan UUIDs and reconcile() built a `suggestedTools`
list with the canonical-UUID row in place of the orphan. But
`applyReconciliation`, which stages the changes for save, only
inserted into `localRemovals` from `mismatch.staleTools` — and orphan
rows aren't stale by name, so they never went into removals. The
canonical row got added; the orphan row lingered. The next Reconcile
pass saw the orphan still in the model and offered the same repair
again, indefinitely. The operator reported: "Reconcile finds the same
problems over and over."

`applyReconciliation` now takes an `orphanIdsToRemove: [String]`
argument and routes those UUIDs into `localRemovals`. The Reconcile
sheet's caller passes `viewModel.orphanTools.map(\.toolId)` from the
ReconciliationViewModel — which holds the pre-repair UUIDs that the
Reconcile pass rewrote.

After saving, the stored model holds only the canonical row, and the
next Reconcile correctly reports no work pending.

## [1.9.3] — 2026-05-26

### Fixed — orphan UUIDs were silently invisible to mismatch detection

1.9.2 introduced orphan-UUID repair in Reconcile, but the detection
flow gated the entire reconcile pass behind `mismatch.hasMismatch` —
which is only true when the **names** in the live MCP differ from
those in the stored model. Orphans are precisely the case where names
match but UUIDs don't, so detection happily reported "All good — live
tools match the stored pricing model" and the repair code never ran.

This release adds a separate orphan scan during detection:

- `ReconciliationViewModel.detectMismatch()` now scans the matched
  rows after the service call and collects any whose stored `toolId`
  differs from `canonicalToolId(forMCPName: toolName)`. The orphans
  are exposed via `viewModel.orphanTools` and `viewModel.hasOrphans`.
- The Reconcile sheet's flow shows the diagnostic phase when there
  are name-level mismatches **or** orphan UUIDs.
- The diagnostic UI now has an orange "Orphan UUIDs" section listing
  the affected rows with a short explanation of what the repair will
  do.
- `reconcile()`'s guard runs when either kind of work is pending.

Operators who tried Reconcile on 1.9.2 and saw "All good" should
update to 1.9.3 and try again — orphans should now be detected and
offered for repair.

## [1.9.2] — 2026-05-26

### Fixed — Reconcile produced orphan tool UUIDs the wheel couldn't look up

When the operator hit **Reconcile** to bring a newly-added MCP tool into
the pricing model, Studio computed the row's `toolId` from the
slug-prefixed protocol name (e.g. `optionality_share_entry`) returned
by MCP `tools/list`. The wheel's `@paid_tool` decorator derives the
lookup UUID from the **bare** capability (`share_entry`), so the two
UUIDs differed and the wheel rejected the call with
"Tool '…' is not yet in the pricing model. Add it to the pricing model
before use." — even though Studio's UI showed the row sitting there at
the operator's chosen price.

Reset Pricing Model didn't have the bug because Reset runs server-side,
where the wheel writes rows with its own canonical UUIDs. The bug only
manifested on ex-post-facto tools incorporated via Reconcile.
Optionality's `share_entry` was the first observed failure;
`send_patron_dm` historically had the same shape and was masked at the
time by running Reset.

Two changes:

1. **Reconcile strips the operator slug prefix before deriving the UUID.**
   New tools land under `capabilityUUID(bareCapability(name))`, which
   matches what the wheel computes. `toolName` continues to be stored
   as the display label so the UI is unchanged.

2. **Reconcile repairs existing orphan UUIDs on each pass.** Studio
   re-derives the canonical UUID for every kept tool and, where it
   differs from the stored `toolId`, rewrites it. The operator's price,
   `priced` flag, category, multipliers, formulas, and bounds are all
   preserved — only the UUID changes. A one-line banner in the review
   phase reports how many rows were repaired so the operator knows the
   migration ran.

Operators who hit this on a tool should update to 1.9.2, open the
affected operator's pricing model, hit Reconcile, and tap Apply once
the repair banner appears.

### Tests

- `ReconciliationUUIDTests.swift` adds parity tests for
  `ToolPrice.capabilityUUID` against reference values generated by
  Python's `uuid.uuid5(DPYC_NAMESPACE, ...)`, plus coverage for the
  new `bareCapability(_:)` and `canonicalToolId(forMCPName:)` helpers.

### Also fixed

- `NostrRelayTests.fetchDMs` was calling the relay service with the old
  `[NostrEvent]` return shape; the service now returns a tuple of
  `(events, relay)`. Destructured at the call site so the test bundle
  compiles again.

## [1.9.1] — 2026-05-20

### Fixed — relay subscriptions silently dying after idle hours

The Pricing Studio's persistent Nostr relay connections stopped detecting
new DMs after a few hours of unattended operation. Root cause: five
overlapping foot-guns in the WebSocket lifecycle.

1. **`.peerClosed` silently swallowed.** Both WebSocket delegates
   (`PersistentRelayConnection`, `NostrRelayService`) had
   `case .viabilityChanged, .reconnectSuggested, .peerClosed: break`.
   When a relay closes the connection cleanly on idle timeout (the
   common case after 30–120 min of silence), Starscream emits
   `.peerClosed` — the App ignored it, never fired `onDisconnect`, never
   triggered `scheduleReconnect()`. State drifted to "connected but
   actually dead." Now wired through `onDisconnect` to engage the
   existing exponential-backoff reconnect machinery.

2. **`.reconnectSuggested` ignored.** Starscream's "you should reconnect"
   signal was ignored. Now honored when `suggested == true`.

3. **`.viabilityChanged` ignored.** iOS network reachability changes
   (WiFi ↔ cellular, going offline) were silently dropped. Now tears
   down when the path becomes non-viable so the reconnect path fires
   on the next foreground.

4. **One-way ping with no pong tracking.** Pings went out every 30s
   but no one watched for the pong. A half-open connection (TCP layer
   says "fine" but the relay has stopped responding) looked identical
   to a healthy one. Now tracks `missedPings`; after 2 unanswered
   pings (~60s of silence), the App force-tears-down the socket and
   reconnects.

5. **No iOS lifecycle observer.** iOS suspends apps within ~30s of
   backgrounding, killing every WebSocket. On foreground return,
   nothing reconnected — what we thought was `.connected` was a
   corpse. Added a `UIApplication.didBecomeActiveNotification`
   observer in `RelaySubscriptionManager` that calls
   `PersistentRelayConnection.revalidate()` on every active
   connection, forcing a fresh handshake.

Net effect: relay subscriptions now self-heal across all four failure
modes (silent relay close, half-open TCP, network change, iOS
suspension). Traffic Log will show new "Sub Stale", "Sub Revalidate",
and "Sub Reconnected" entries when these paths fire.


## [1.9.0] — 2026-05-19

### Changed — sync with tollbooth-dpyc 0.25.0

Picks up the wheel's runtime-name + DRY pass:

- **Identity proofs sign the runtime tool name** (`<slug>_<capability>` —
  what the operator exposes on the MCP wire and lists in its pricing
  model). The capability seed never crosses the server boundary. Every
  proof signer in `MCPService` now signs the runtime name; `TestCallView`
  signs `selectedTool.toolName` directly.
- **Slug resolution via `<slug>_service_status` marker** — every Tollbooth
  operator exposes that standard tool, so the App finds it in `tools/list`
  and strips the suffix to get the slug. Robust against operators that
  delegate oracle tools under `<slug>_oracle_*`.
- **One canonical helper for the slug+capability join** —
  `MCPService.runtimeName(for:endpointURL:)`. The previous three
  inline `<slug>_<cap>` constructions in `argsWithProof`,
  `signRuntimeProof`, and the `set_pricing_model` signer all delegate to it.
- **Single proof-tactic dispatch** — `argsWithProof` (and Test Call's
  proof auto-fill) prefer inline Schnorr signing from the Keychain nsec
  when available, falling back to a cached poison token from a prior
  `receive_npub_proof`, falling back to empty. No more split between
  "restricted" and "paid" tool kinds — the wheel accepts either tactic
  at every gate.

### Fixed

- Top-Off and Test Call no longer drop the SF Symbol on `.borderedProminent`
  buttons. Replaced `Label(_, systemImage:)` with `HStack { Image; Text }`.
- `AccountStatementView` pull-to-refresh no longer reports "cancelled"
  on a successful balance fetch. The network call runs inside
  `Task.detached` so SwiftUI body re-renders don't cancel it.


## [1.5.4] — 2026-03-20

Authority claim UX overhaul, traffic log filtering, and rolling buffer.

### Added
- **Quick claim path** — when the entered nsec derives to the Authority's
  npub, a primary "Claim Authority" button saves the nsec locally without
  invoking the full MCP DM challenge protocol.
- **Full MCP claim protocol (4-phase)** — ClaimAuthoritySheet rewritten as
  a guided multi-phase flow: Form → Challenge → Verifying → Result. Inline
  `CourierPayloadView` for challenge DM handling without leaving the modal.
- **MCP claim verification** — after sending credentials, the app
  automatically calls `confirm_authority_claim` and `check_authority_approval`
  to complete the 3-step MCP protocol and show approval/denial result.
- **`MCPService.callConfirmAuthorityClaim()`** — step 2/3 of Authority claim.
- **`MCPService.callCheckAuthorityApproval()`** — step 3/3 of Authority claim.
- **Traffic Log: Nostr toggle** — toggle in header to show/hide Nostr DM
  events (DM Poll, DM Fetch, DM Sent, DM Decrypt). Off by default to reduce
  noise.
- **Traffic Log: regex filter** — search bar with regex pattern matching
  against entry labels, details, URLs, and request/response bodies.
  Invalid patterns show a warning icon.
- **Traffic Log: rolling buffer** — capped at 2,000 entries with oldest-first
  eviction. In-memory only; resets on app restart.

### Fixed
- **Send Credentials double-click** — button now disables after click and
  shows "Sending..." progress indicator to prevent duplicate submissions.
- **MCP JSON response shown as success** — `{"success":false,"error":"..."}`
  was displayed with a green checkmark. Added `parseResponse()` that parses
  JSON first and checks the `success` field before falling back to keyword
  heuristics.
- **Courier provenance placement** — moved from DisclosureGroup at bottom
  (looked like a next-action chevron) to compact service badge with info
  popover at top of the payload view.

## [1.5.3] — 2026-03-20

Adopt Operator feature, Courier challenge fixes, and unregistered operator UX.

### Added
- **Adopt Operator** — Authority detail view gains a [+ Adopt Operator] button
  that presents a sheet with a dropdown of unclaimed operators. Selecting one
  calls `register_operator` on the Authority's MCP endpoint to register the
  operator with the DPYC community.
- **`MCPService.callRegisterOperator()`** — new MCP tool call for operator
  registration via Authority SSE endpoint with Bearer auth.
- **`AdoptionStatus` state machine** on `AuthorityCollectionViewModel` —
  tracks idle/registering/success/failed for the adoption flow.
- **"Not Registered" UX** — operators not yet in the DPYC registry now show
  a helpful `ContentUnavailableView` with 4-step registration guidance instead
  of a generic "Connection Error."
- **Two new `CourierPayloadTests`** — `testGreetingFieldsNotDuplicated` and
  `testEditingPlaceholderClearsNeedsInput` covering both parser fixes.

### Fixed
- **Courier challenge duplicate fields** — the `@@@` field regex was running
  against the full DM text including instruction text ("Reply with: claim =
  @@@yes@@@"), producing a duplicate "claim" row. Parser now restricts field
  extraction to the `--- Credential Payload ---` section only.
- **Courier placeholder fields permanently stuck** — `isPlaceholder` was an
  immutable `let` set at parse time; editing the value never cleared
  `needsInput`, so the "Send Credentials" button stayed permanently disabled.
  `needsInput` now checks the current value instead of the original parse flag.

## [1.5.2] — 2026-03-20

Nostr relay WebSocket fix, parallel DM polling, About screen.

## [1.5.1] — 2026-03-18

Five bug fixes and UX improvements from campaign design testing.

### Fixed
- **Bulk Discount tiers showing `[null, null]`** — `AnyCodableValue` lacked a
  `.dictionary([String: AnyCodableValue])` case, causing tier objects from JSON
  to fall through to `.null`. Added dictionary support to the enum, decoder,
  encoder, description, and the `anyCodableValue(from:)` bridge in PricingViewModel.
- **Existing server pipeline mislabeled in consultant context** — `buildConsultantContext()`
  now labels the server model's pipeline as `[EXISTING server model — may be outdated]`
  so it cannot be confused with the proposed campaign in the Grok second opinion transcript.

### Added
- **Auto-feed Grok feedback to Claude** — dismissing the Second Opinion sheet now
  automatically sends Grok's suggested changes to Claude as a follow-up message,
  so Claude can adjust the proposal without requiring the user to manually tap "Revise."
  The manual fork-based "Revise Campaign" button remains for explicit revision control.
- **Second opinion availability hint** — the Second Opinion button now appears (disabled
  with `.help()` tooltip) as soon as messages exist, explaining "Available after Synthesis
  stage (stage 6 of 6)." Previously the button was completely hidden until stage 6.

### Changed
- **Relay error logging quieted** — individual relay failures no longer appear in the
  traffic log (removed `TrafficLogger.shared.log(.error, ...)` from `fetchFromRelay` and
  `publishToRelay`). Relay OK=false rejections downgraded from `.error` to `.inbound`.
  Only OS-level `logger.debug` remains for individual failures. Aggregate "all relays
  failed" logging by callers (e.g. `NostrDMService.sendDM`) is unchanged.
- **`ConstraintParamEditor` switch exhaustiveness** — added `.dictionary` case to the
  `stringFrom(_:)` helper to match updated `AnyCodableValue` enum.

## [1.5.0] — 2026-03-16

Per-stage isolated conversations, MCP push-on-apply, patron alias
re-evaluation, and monospaced markdown tables.

### Added
- **Per-stage isolated conversations** — each interview phase (1-6) is now
  its own independent conversation thread. Claude receives only that stage's
  messages plus synthesized context from prior stages via `InterviewProgress.Insights`.
  Stage stepper switches between isolated conversations; sending from a past stage
  appends directly to that stage's thread without artificial "Let's revisit" messages.
- **Stage-specific system prompts** — `buildStageSystemPrompt(stage:context:)` injects
  phase-specific focus instructions and prior-stage context summaries, keeping Claude
  on-topic within each phase.
- **Apply Model pushes to MCP** — "Apply Model" now shows a confirmation dialog
  offering "Push to MCP" (calls `savePricing(for:)` to push pricing to the operator's
  endpoint) or "Keep as Local Edit". Error alert on push failure.
- **Patron alias re-evaluation on nsec change** — editing a patron's nsec now
  re-evaluates alias status: if the new npub collides with another patron, aliasOf
  is set; if unique, aliasOf is cleared. Orphaned aliases (other patrons whose
  aliasOf pointed at the old display name) are also re-evaluated.
- **Campaign.stageMessagesJSON** — new SwiftData property for per-stage message
  storage. Lightweight migration: defaults to nil for existing campaigns.
- **Campaign.migrateToStageMessages()** — groups flat `messagesJSON` by stageNumber
  into per-stage storage on first load.
- **Campaign encode/decode helpers** — `encodeDicts`/`decodeDicts` promoted to
  internal for per-stage serialization.
- **Export by stage** — transcript export now organized with `## Phase N: Label`
  section headers instead of flat message list.
- **Campaign deploy sidebar** — operator sidebar shows campaign slots with deploy
  context menu, compare multi-select, and LIVE badge.
- **CampaignSummaryBuilder** — extracted stateless service for building focused
  text summaries of campaign data for LLM consumption (second opinion, reshape, revision).
- **ResponseParser** — extracted stateless service owning all regex parsing:
  PROGRESS, REVENUE, CAMPAIGN_JSON, display cleanup, review section parsing,
  and stage transition splitting.
- **StageClassifier** — extracted AI and keyword-based stage classification.
- **InterviewAnalysis** / **PricingProposal** / **PeerReview** — extracted value
  types for structured interview artifacts.

### Changed
- **Monospaced markdown tables** — table header and body fonts in
  `MarkdownContentView.tableView()` now use `.system(.caption, design: .monospaced)`
  matching the code block pattern, so numeric columns align properly.
- `PricingConsultantViewModel.stageMessages` replaces flat `messages` array as the
  primary storage. Computed `messages` property retained for backward compatibility.
- `saveCampaign`/`autoSave` now persist both `stageMessages` and flat `messages`
  (backward compat safety net for one release cycle).
- `loadCampaign` reads from `stageMessagesJSON` if available; otherwise migrates
  from flat `messagesJSON` and persists the grouped result.
- `forkFromMessage`/`whatIfBranch` now operate stage-aware.
- `SecondOpinionViewModel` delegates parsing to `ResponseParser` and summary building
  to `CampaignSummaryBuilder`; uses shared `ReviewSection`/`ReviewVerdict` types.
- `Operator` model gains `deployedCampaignName` display property.
- `OperatorCollectionViewModel` gains campaign slot management, deploy, and compare.

## [1.4.0] — 2026-03-16

Secure Courier credential delivery, Authority claim flow, operator identity
proofs, stage-divided interview display, and AI-guided pricing enhancements.

### Added
- **Operator proof (NIP-98)** — `OperatorProofService` signs kind-27235 Nostr events
  to prove operator authority for RESTRICTED MCP tool calls without rebinding the
  patron session; server-side verification via `tollbooth.operator_proof`
- **Tool role classifier** — `ToolRole` enum (`.patron` / `.operator` / `.ambiguous`)
  and `ToolRoleClassifier` to determine which identity a given MCP tool requires
- **Identity picker** — `IdentityPickerView` sheet for selecting among stored operator
  npubs when multiple identities exist or the tool role is ambiguous
- **Pricing diff view** — `PricingDiffView` shows side-by-side comparison of two
  pricing models: tool-by-tool price deltas, pipeline divergences, and total cost
  summary with directional arrows
- **Full-screen interview view** — `FullScreenInterviewView` with stage sidebar,
  BLUF summary, revenue projection table, and per-phase transcript navigation;
  accessible via expand button in consultant header
- **Stage-divided message display** — interview messages grouped by phase with
  section headers (icon + "Phase N: Label" + divider) in the default view
- **BLUF prompt instruction** — fallback prompt now requires a Bottom Line Up Front
  paragraph in the Recommendation phase: philosophy, 3 revenue scenarios, key constraint
- **A/B/C variant proposals** — prompt instructs Claude to present three labeled
  pricing variants (conservative, balanced, aggressive) with comparison table
- **Markdown table formatting** — prompt requires all pricing data as markdown tables
  instead of raw JSON during the interview; JSON only on final approval
- **Save confirmation dialog** — "Save to Operator" button now shows a confirmation
  dialog with operator name and edit summary before overwriting
- **Compare button** — unified save bar includes "Compare" to preview edits as a
  side-by-side diff before saving
- **CourierPayload parser** — extracts `key = @@@value@@@` credential fields, greeting,
  anti-replay poison, and provenance metadata from Secure Courier DMs
- **CourierPayloadView** — inline editable form for Courier credential fields with
  send button, provenance disclosure, and status indicators
- **MessageBubble Courier rendering** — DMs containing `@@@` fields render as
  interactive credential forms instead of plain text; orange lock.shield badge
- **Authority claim flow** — `ClaimAuthoritySheet` accepts operator nsec, derives
  npub, and calls `register_authority_npub` on the Authority MCP endpoint to begin
  the DM challenge-response protocol
- **AuthorityDetailView claim button** — "Claim Authority" button on Authority detail
  when an MCP endpoint is available
- **PricingStudioTests target** — new XCTest target with 14 `CourierPayloadTests`
  covering parsing, placeholders, serialization round-trip, and edge cases
- **Shared scheme** — `xcshareddata/xcschemes/PricingStudio.xcscheme` with test action
  wired to PricingStudioTests
- **Second opinion sheet** — LLM provider abstraction with xAI Grok and Anthropic
  backends for pricing consultant second opinions
- **LLM provider protocol** — `LLMProvider` with `AnthropicProvider` and `XAIProvider`
  implementations; API key management via `AssistantAPIKeySheet`

### Fixed
- **MessageBubble binding bug** — replaced `if var payload` local copy pattern with
  direct `Binding` projection on `$courierPayload` to prevent edits silently vanishing
- **Ephemeral agent reply target** — reply now prefers provenance `operatorNpub`
  (converted to hex) over `dm.senderPubkeyHex` for self-DM onboarding flows
- **Empty bearer token guard** — `ClaimAuthoritySheet` now rejects missing/empty
  bearer tokens with an explicit error instead of sending empty `Authorization` header
- **Keychain save failure surfacing** — nsec Keychain save errors are caught and
  displayed to the user, aborting the claim flow on failure
- **nsec memory zeroing** — `ClaimAuthoritySheet` clears nsec `@State` on dismiss

### Changed
- `MCPService.callSetPricingModel()` accepts optional `operatorNpub` and sends
  `operator_proof` in tool call arguments when provided
- `PricingViewModel.savePricing()` resolves operator identity before saving,
  passing proof to the MCP service
- `PricingViewModel` gains `mergedPreview(from:)` for diff view integration
- `PricingDetailView` gains save confirmation dialog and compare button in
  unified save bar
- `SettingsSheet` consolidated with AI API keys (Anthropic + xAI) alongside
  Nostr relay configuration
- `NostrEventKind` gains `.httpAuth` case (kind 27235) for operator proofs
- `PricingConsultantViewModel` fallback prompt restructured: six named phases,
  markdown table formatting, BLUF requirement, A/B/C variant instructions,
  PROGRESS stage name corrected from "synthesis" to "recommendation"
- `MCPService` gains `callRegisterAuthorityNpub()` for Authority claim protocol
- `AuthorityCollectionViewModel` gains `ClaimStatus` state machine and
  `initiateAuthorityClaim()` async method; status resets to `.idle` on new claim
- `ContentView` wires `authorityVM` into `AuthorityDetailView` and presents
  `ClaimAuthoritySheet`
- Renamed "Adopt Operator" → "Claim Authority" across UI, view models, and file names
- Default branch renamed from `master` to `main`

## [1.3.1] — 2026-03-15

Post-release fixes and UX improvements from physical iPad testing.

### Fixed
- `.gitignore` now correctly excludes `xcuserdata/` directory and `*.xcuserstate`
- `PreviewData` references guarded with `#if DEBUG` for release builds
- Device ID used instead of display name in Makefile (smart apostrophe broke `devicectl`)
- Export method changed from deprecated `development` to `debugging`
- CloudKit entitlements removed until models are migrated (presence alone triggers
  CloudKit mode in SwiftData, causing launch crash)

### Added
- **nsec-first Add flows** — Add Operator and Add Authority sheets accept nsec
  with auto-derived npub via `NostrKeyService`; green checkmark on valid derivation
- **Autofill pairing** — nsec uses `.textContentType(.password)`, display name uses
  `.textContentType(.username)` for iPadOS keyring autofill
- **Edit Authority nsec** — `EditAuthoritySheet` gains nsec field with show/hide
  toggle, matching `EditOperatorSheet`
- **Tappable sidebar icons** — push Authority/Operator icon to open edit sheet;
  green shield badge when nsec stored in Keychain
- **Clickable empty states** — "No X yet" labels replaced with `Button` to open
  the corresponding Add sheet
- **Patron identity aliases** — reusing an nsec across Patrons triggers alias
  confirmation; aliases tracked with `aliasOf` field and purple badge in sidebar

### Changed
- `Patron.npub` no longer has `@Attribute(.unique)` — multiple patrons can share
  an npub when one is an alias of another
- `PatronCollectionViewModel` adds duplicate-npub detection and alias confirmation
  flow (`PendingAlias`, `confirmAlias`, `cancelAlias`)
- `PatronSidebarView` uses `.id` instead of `.npub` for selection comparison

## [1.3.0] — 2026-03-15

CloudKit sync, OTA deployment, and operator balance infographic.

### Added
- **CloudKit sync** — SwiftData model container configured with
  `cloudKitDatabase: .automatic`; entitlements for iCloud container
  `iCloud.com.tollbooth.dpyc.PricingStudio` with CloudKit services
- **OTA iPad deployment** — Makefile with `archive`, `export`, `install`,
  and `wifi-install` targets using `xcodebuild` + `devicectl`; includes
  `ExportOptions.plist` for automatic signing
- **Balance infographic** — `MCPService.callAccountStatementInfographic()`
  fetches SVG/PNG from operator MCP; `PatronAccountViewModel` manages
  per-operator infographic state; `PatronDetailView` shows "Statement"
  button opening infographic sheet with SVG (via WKWebView) or PNG render

### Changed
- `PricingStudioApp` uses `ModelConfiguration` + `ModelContainer` init
  instead of Scene modifier for CloudKit database configuration
- `OperatorBalanceCard` now receives full `Patron` and `Operator` objects
  for infographic auth flow

## [1.2.0] — 2026-03-15

Interview Progress v2 — 9 feedback items from physical iPad testing.

### Fixed
- PROGRESS regex now uses `.dotMatchesLineSeparators` so stage advances
  reliably even when Claude splits the JSON across lines (#4)
- Added debug logging for PROGRESS parse success/failure

### Added
- **Shared MarkdownContentView** — extracted block-level markdown renderer
  (code blocks, tables, headings, lists, dividers) used by both
  AssistantPanelView and PricingConsultantView (#6)
- **Markdown in insight summaries** — demand/value/cost fields now render
  markdown instead of plain text (#7)
- **Stage-based message filtering** — messages tagged with stage number at
  creation; `displayedMessages` filters by selected stage (#5)
- **Tappable stepper** — tap completed/current stages to view that stage's
  messages; orange highlight and "Viewing [Stage]" banner (#1)
- **Stage revisit flow** — sending from a past stage auto-prepends
  "Let's revisit [Stage Name]" message
- **Export transcript** — ShareLink button exports full interview as
  Markdown with role headers, timestamps, and stage numbers (#3)
- **Philosophy detection** — probes operator pricing philosophy
  (capitalist/balanced/charitable) with Austrian economics guidance;
  badge in header and insight card (#2)
- **Revenue projection** — TAM/SAM/SOM analysis and 3-scenario forecast
  table parsed from `<!-- REVENUE {...} -->` block; persisted on
  Campaign (#8)
- **A/B/C campaign comparison** — side-by-side cards with revenue bar
  charts, annual projections, winner crowns, and recommendation
  labels; accessible from campaign list multi-select (#9)

### Changed
- `AssistantMessage` gains `stageNumber: Int?` (backward-compatible)
- `Campaign` gains `projectionsJSON: Data?` (no migration needed)
- `InterviewProgress.Insights` gains `philosophy: String?`
- Community prompt updated with philosophy probe, revenue projection
  instructions, and strengthened PROGRESS formatting rules

## [1.1.1] — Prior release
## [1.1.0] — Prior release
## [1.0.0] — Initial release
