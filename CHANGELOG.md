# Changelog

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
