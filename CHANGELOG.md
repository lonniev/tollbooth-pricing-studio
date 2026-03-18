# Changelog

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
