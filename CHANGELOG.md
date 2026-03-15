# Changelog

## [1.4.0] — 2026-03-15

Secure Courier credential delivery, Authority claim flow, and test infrastructure.

### Added
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
