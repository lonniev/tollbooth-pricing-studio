# Advisor → Consulting Team UX Redesign

**Goal.** Replace the single linear chat-with-phase-circle with a team of six
named consultants the user meets one at a time, each with their own persona,
transcript, and proposed edits. The user can switch between consultants in any
order, save in-progress advice, and ask for a final synthesized proposal.

**Non-goal.** Concurrent multi-agent streaming. Only one consultant streams at
a time; switching consultants is a UI navigation, not a parallel execution.

---

## 1. The Cast — locked bench

The team is six dead Austrian / free-market / sound-money historical figures.
Each persona's **bio** appears on the business card; each persona's **voice**
is blended into the system prompt so the LLM speaks in character.

| # | Stage          | Consultant                        | Title                       | Lifespan  | Known for                                                                      |
|---|----------------|-----------------------------------|-----------------------------|-----------|--------------------------------------------------------------------------------|
| 1 | inventory      | **Carl Menger**                   | Market Research Analyst     | 1840–1921 | Founded the Austrian School; *Principles of Economics* (1871); subjective theory of value; orders of goods. |
| 2 | demand         | **Friedrich von Wieser**          | Demand Analyst              | 1851–1926 | Coined "marginal utility" (*Grenznutzen*) and "opportunity cost"; *Natural Value* (1889). |
| 3 | value          | **Eugen Böhm-Bawerk**             | Valuation Specialist        | 1851–1914 | *Capital and Interest* (1884–89); time preference; roundabout production; three-time Austrian Finance Minister. |
| 4 | cost           | **Philip Wicksteed**              | Cost Analyst                | 1844–1927 | *Common Sense of Political Economy* (1910); marginal cost as opportunity cost; clearest exposition in the marginalist tradition. |
| 5 | constraints    | **Ludwig von Mises**              | Mechanism Designer          | 1881–1973 | *Human Action* (1949); the calculation problem (1920); praxeology; the Mises seminar in Vienna. |
| 6 | recommendation | **Friedrich Hayek**               | Managing Partner            | 1899–1992 | "The Use of Knowledge in Society" (1945); Nobel 1974; *The Road to Serfdom*; prices as the synthesis of distributed information. |

Hayek is *both* the sixth consultant and the synthesizer. He has tools the
others don't (read peer proposals, merge into final `PricingProposal`,
preview deployment). Treating him as a peer keeps the UI uniform — one card
per consultant, no special chrome. The choice is also thematically right:
Hayek's whole thesis is that prices are the synthesis of distributed
knowledge no single mind can hold, which is exactly what step 6 does.

### Voice blending

Each consultant's `systemPromptCore` includes a short **voice cue** so Claude
channels the figure's documented intellectual style:

- **Menger** — methodical, observational; insists on cataloging before theorizing; asks "what *is* this good, exactly?"
- **Wieser** — thoughtful, sociological; frames demand as forgone alternatives; "what would the user have done instead?"
- **Böhm-Bawerk** — precise, polemical when needed; thinks present-vs-future value; willing to challenge sloppy reasoning.
- **Wicksteed** — clear, plain, almost pastoral (he was a Unitarian minister); explains complex marginal analysis in everyday language.
- **Mises** — systematic, deductive from first principles; unsentimental; sharp when an argument doesn't follow from premises.
- **Hayek** — synthesizing, integrative; humble about what any one analyst can know; emphasizes that the team produced the answer.

Voice cues are explicit instructions, not vague hints — e.g., "When proposing
deltas, reference the relevant peer's analysis by name" — to keep the
in-character behavior measurable rather than performative.

---

## 2. Data Model — minimum viable extension

Add one field to `Campaign`:

```swift
/// Per-consultant working notes — keys are stage numbers (1–6).
/// Each consultant's structured insights, proposed deltas, and peer-review
/// reactions are stored here and surveyed by other consultants on each turn.
var consultantNotesJSON: Data?

var consultantNotes: [Int: ConsultantNote] { get/set }
```

New `ConsultantNote` struct (file: `PricingStudio/Models/ConsultantNote.swift`):

```swift
struct ConsultantNote: Codable {
    var lastMetAt: Date?            // nil until first meeting
    var lastSawPeerUpdateAt: Date?  // for "new since last visit" badge
    var summary: String             // one-paragraph "what I concluded"
    var proposedDeltas: [PricingDelta]   // structured edits to the model
    var openQuestions: [String]     // things the consultant wants the user to decide
    var concernsAboutPeers: [Int: String]  // stage# → critique
}

enum PricingDelta: Codable {
    case toolPrice(toolName: String, sats: Int, rationale: String)
    case addConstraint(type: String, params: [String: String], rationale: String)
    case removeConstraint(index: Int, rationale: String)
    case projectionAssumption(scenario: String, field: String, value: String)
}
```

The existing `proposal: PricingProposal` remains the **published** state; per-
consultant `proposedDeltas` are the **uncommitted** edits Rita merges on
"prepare final proposal."

No new SwiftData entity. No separate "draft" type. Migration is trivial: the
field defaults to `nil`, decodes to `[:]`, and the sidebar treats every
consultant as "unvisited" for legacy campaigns.

---

## 3. Persona definitions — code-only

New file `PricingStudio/Services/Consultant.swift`:

```swift
struct Consultant: Identifiable, Hashable {
    let stage: Int                  // 1…6
    let id: String                  // stable: "quentin", "dana", …
    let displayName: String         // "Dana"
    let title: String               // "Demand Analyst"
    let avatarSystemName: String    // SF Symbol for the business card
    let accentColor: Color
    let systemPromptCore: String    // persona + responsibilities, no peer state
}

enum ConsultantRoster {
    static let all: [Consultant] = [ /* six entries */ ]
    static func forStage(_ n: Int) -> Consultant { all[n - 1] }
}
```

The full system prompt sent to Claude on a turn is:

```
<persona> systemPromptCore
<peer briefing> compact summary of every other consultant's note
<working model> current PricingProposal as JSON
<your prior history> the per-stage transcript (already in stageMessages[stage])
```

The peer-briefing builder lives in the view model and runs every turn — cheap,
keeps context fresh when the user revisits a consultant after their peers
moved.

---

## 4. AnthropicService — minimal change

Already has the agentic tool-use loop (commit `4a77206`). Three additions:

1. **System prompt assembly** — instead of one global system prompt, accept a
   `Consultant` and assemble the four-part prompt above per turn.
2. **Tool surface** — each consultant gets a small toolkit:
   - `read_working_model()` → returns current `PricingProposal` JSON
   - `read_peer_notes(stage: Int)` → returns one peer's `ConsultantNote`
   - `propose_delta(...)` → appends to *this* consultant's `proposedDeltas`
   - `flag_concern(stage: Int, concern: String)` → records peer-critique
   - Rita additionally gets `merge_proposal()` and `preview_deployment()`
3. **No streaming-loop change.** The phase-circle / mid-stream PROGRESS detection
   becomes per-consultant; the existing extractor already runs per token.

Tool execution is local to the app (no MCP roundtrip) — these tools mutate
`Campaign.consultantNotes` and read `Campaign.proposal`. Fast, deterministic.

---

## 5. UI — sidebar of business cards

New file `PricingStudio/Views/ConsultantSidebar.swift`. Replaces the phase
circle inside `PricingConsultantView`.

```
┌────────────────────────────────────────────────────────────────────┐
│ ConsultantSidebar (NavigationSplitView sidebar, ~260pt wide)       │
│                                                                    │
│  ┌─────────────────────────┐                                       │
│  │ 🧰 Quentin              │  ← business card per consultant       │
│  │    Quartermaster        │                                       │
│  │    "12 tools cataloged" │  ← latest summary line                │
│  │    ● new since visit    │  ← badge when peers updated           │
│  └─────────────────────────┘                                       │
│  …5 more cards…                                                    │
│                                                                    │
│  ──────────────────                                                │
│  [ Save & put away ]                                               │
│  [ Prepare final proposal ]   ← jumps to Rita with merge primed    │
└────────────────────────────────────────────────────────────────────┘
```

Card visual states (drives a small `enum CardState`):

- **Unvisited** — muted, grayscale avatar, "Tap to meet"
- **Active** — accent border, "In session"
- **Visited, peers unchanged** — normal
- **Visited, peers changed since** — accent dot + "New input from peers"
- **Has open questions for you** — badge with `?` icon

Detail pane is the existing chat view, scoped to the active consultant's
`stageMessages[stage]`. Header shows "Now meeting with Dana — Demand Analyst"
+ a "What Dana has concluded so far" expander showing her current
`ConsultantNote.summary` and `proposedDeltas`.

Existing `navigateToStage` / `revisitStage` / `redoStage` machinery in
`PricingConsultantViewModel` becomes the action layer behind tapping a card.

---

## 6. Save / resume / finalize

- **Save & put away** — already exists as `Campaign.isHidden = true`. Reuse.
- **Resume** — already exists as the campaign list sheet. Reuse.
- **Prepare final proposal** — taps Rita's card with a hint flag that makes
  her opening turn say *"I've reviewed everyone's notes — here's the draft I
  propose to merge…"* and pre-emptively call `merge_proposal()` so the user
  sees the consolidated `PricingProposal` immediately. User then converses
  with Rita to refine before deploying.
- **Apply** — the existing deploy flow is unchanged. `merge_proposal()`
  writes into `Campaign.proposal`; the deploy button does what it does today.

---

## 7. Work units (stop after each for review)

1. **Roster + ConsultantNote model.** New files only; no behavior change.
   *Files:* `Services/Consultant.swift`, `Models/ConsultantNote.swift`,
   `Models/Campaign.swift` (add `consultantNotesJSON` + accessor).
   *Stop.* Build green, no UI change yet.

2. **AnthropicService — persona-scoped system prompt.** Accept a `Consultant`
   parameter; assemble the four-part prompt; keep existing tool-use loop.
   *Files:* `Services/AnthropicService.swift`,
   `ViewModels/PricingConsultantViewModel.swift` (callers).
   *Stop.* Existing chat still works; each stage now produces in-character
   responses. Visible win even before the sidebar lands.

3. **Local tools — `propose_delta`, `read_peer_notes`, etc.** Wire as Claude
   tool-use blocks the AnthropicService loop already understands. Mutations
   land in `Campaign.consultantNotes`.
   *Files:* `Services/AnthropicService.swift`,
   `ViewModels/PricingConsultantViewModel.swift`.
   *Stop.* Verify via console logs that consultants are calling the tools
   and notes are persisting.

4. **Sidebar UI — business cards.** Replace phase circle with sidebar; tapping
   a card calls the existing `navigateToStage`. Card state derived from
   `Campaign.consultantNotes` timestamps.
   *Files:* `Views/ConsultantSidebar.swift` (new),
   `Views/PricingConsultantView.swift` (rewire layout).
   *Stop.* End-to-end smoke: meet Quentin, switch to Dana, switch back.

5. **Rita — synthesizer behavior.** Special opening turn, `merge_proposal()`
   tool, "Prepare final proposal" sidebar action.
   *Files:* `Services/AnthropicService.swift`,
   `Views/ConsultantSidebar.swift`.
   *Stop.* Walk through a campaign end-to-end: meet 5, then ask Rita.

6. **Polish.** Card badges (new-since-visit, has-open-questions), peer-
   briefing budget tuning, Rita's merge preview UX.
   *Files:* incremental across the same set.

---

## 8. Open questions before I start step 1

- **Naming.** The Q/D/V/C/C/R alphabet roster above — keep, replace, or let
  you provide a name list? (Easy to slot in later either way.)
- **Avatars.** SF Symbols on a colored disc, or do you want to commission
  illustrated business-card art down the line?
- **Persona voice tone.** Crisp/professional, conversational, or quirky
  (each consultant has a distinct verbal tic)? Affects `systemPromptCore`.
- **Peer briefing budget.** Cap each peer summary at ~200 tokens so a six-
  consultant briefing fits in ~1.2k tokens of context? Or let Rita see more?
- **Tool transparency.** Show the user every `propose_delta` as a chat
  bubble ("Dana proposed: get_weather → 5 sats"), or only surface them in
  the sidebar's expander? Bias: show inline; reinforces what the consultant
  is doing.
