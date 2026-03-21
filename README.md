# Pricing Studio

[![Platform](https://img.shields.io/badge/platform-iPadOS_18-black?logo=apple)](https://developer.apple.com/ipados/)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange?logo=swift)](https://www.swift.org)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

Native iPadOS workbench for [DPYC](https://github.com/lonniev/dpyc-community) Operators to inspect, design, simulate, and deploy Tollbooth pricing models. Connects to any Tollbooth MCP endpoint over SSE with OAuth2 Bearer auth. Includes a built-in Nostr DM client for multi-identity encrypted messaging and a 6-phase AI pricing consultant powered by Claude.

<p align="center">
  <img src="assets/pricing-studio-bluf-mar18.jpeg" width="80%" alt="Pricing Studio — BLUF revenue projections and constraint pipeline" />
</p>

## Features

### Live Pricing Editor

Load any Operator's pricing model from its MCP endpoint. Edit per-tool prices inline, add or remove constraint pipeline steps (free trial, bulk discount, loyalty, happy hour, surge, floor, cap), and diff your changes against the live server state before pushing.

<p align="center">
  <img src="assets/pricing-studio-pipeline-mar18.jpeg" width="80%" alt="Pricing Studio — constraint pipeline editor" />
</p>

### 6-Phase Pricing Campaign Interview

An AI pricing consultant (Claude) walks you through a structured 6-phase interview to design a complete pricing model from scratch:

1. **Discovery** — understand the Operator's service, market, and goals
2. **Demand Analysis** — probe usage patterns and price sensitivity
3. **Value Assessment** — map tool value to willingness-to-pay
4. **Cost Analysis** — establish floor costs and margin requirements
5. **Competitive Context** — position against alternatives
6. **Recommendation** — Bottom Line Up Front with 3 revenue scenarios (conservative, moderate, aggressive), A/B/C variant proposals, and a deployable pricing model

Each phase runs as an isolated conversation with synthesized context from prior stages. Revisit any stage to refine without losing progress. Fork campaigns for what-if exploration.

### Second Opinion from Grok

Before deploying, get an independent pricing review from xAI Grok. The second opinion is structured into section cards (Strengths, Risks, Alternatives, Revenue Impact, Verdict) with automatic feedback loop — dismissing the review feeds Grok's suggestions back to Claude for revision.

### Multi-Identity Nostr Chat

A full encrypted DM client built on NIP-04, NIP-44, and NIP-17 — no external dependencies. Switch between Operator, Authority, and Patron identities for independent conversation threads. Features include:

- **Identity switching** — each sidebar entity has its own Nostr keypair and conversation history
- **Background DM polling** — parallel relay fetching across all identities with unread indicators
- **Secure Courier** — interactive credential forms rendered inline from `@@@field@@@` payloads with anti-replay poison and provenance metadata
- **Authority claim protocol** — 4-phase guided flow for claiming Authority control via Nostr DM challenge-response

### Network Topology

Visual graph of the DPYC Honor Chain hierarchy: Prime Authority &rarr; Authorities &rarr; Operators. Auto-discovers upstream Authorities when loading Operator pricing models.

<p align="center">
  <img src="assets/pricing-studio-launch.png" width="50%" alt="Pricing Studio — network topology view" />
</p>

### Traffic Log

Real-time inspector for all MCP, HTTP, and Nostr relay traffic. Nostr events hidden by default (toggle on to see DM poll/fetch/send/decrypt). Regex search across labels, URLs, and request/response bodies. Rolling buffer capped at 2,000 entries.

## Architecture

| Layer | Technology |
|---|---|
| UI | SwiftUI `NavigationSplitView` — three-pane iPad layout |
| Persistence | SwiftData with optional CloudKit sync |
| MCP Transport | SSE (Server-Sent Events) with OAuth2 Bearer tokens |
| Nostr | NIP-04 + NIP-44 encryption, NIP-17 gift-wrap, Starscream WebSocket |
| AI Consultant | Claude (Anthropic API) — streaming, 6-phase isolated conversations |
| Second Opinion | xAI Grok (preferred) or Claude fallback |
| Identity | Nostr keypairs (nsec/npub) stored in iOS Keychain |

### Entity Model

- **Authority** — certification body in the DPYC Honor Chain with MCP endpoint
- **Operator** — MCP service provider with pricing model, tool catalog, and constraint pipeline
- **Patron** — end user with Nostr identity for multi-identity DM support
- **Campaign** — persisted pricing interview with stage messages, revenue projections, and deployment state

## Build & Deploy

Requires Xcode 16+ and an Apple Developer account for device deployment.

```bash
# Fast incremental debug build (device)
make dev

# Build + deploy to iPad over WiFi
make dev-wifi

# Full release archive + signed IPA
make export

# Run unit tests (simulator)
make test-ui-sim
```

| Target | Description |
|---|---|
| `make dev` | Debug build for device (~30s incremental) |
| `make dev-wifi` | Debug build + WiFi install |
| `make dev-install` | Debug build + USB install |
| `make archive` | Release .xcarchive |
| `make export` | Archive + signed IPA |
| `make test-ui-sim` | XCUITests on simulator |
| `make test-bdd-sim` | BDD feature tests on simulator |

## Testing

| Target | Framework | Coverage |
|---|---|---|
| `PricingStudioTests` | XCTest | Model/service unit tests (CourierPayload, etc.) |
| `PricingStudioUITests` | XCUITest | 6 UI automation test classes |
| `PricingStudioBDDTests` | Gherkin/Cucumberish | 4 `.feature` files for business journeys |

## Prior Art & Attribution

The methods, algorithms, and implementations contained in this repository may represent original work by Lonnie VanZandt, first published on March 12, 2026. This public disclosure establishes prior art under U.S. patent law (35 U.S.C. 102).

All use, reproduction, or derivative work must comply with the Apache License 2.0 included in this repository and must provide proper attribution to the original author per the [NOTICE](NOTICE) file.

### How to Attribute

If you use or build upon this work, please include the following in your documentation or source:

    Based on original work by Lonnie VanZandt and Claude.ai
    Originally published: March 12, 2026
    Source: https://github.com/lonniev/tollbooth-pricing-studio
    Licensed under Apache License 2.0

Visit the technologist's virtual cafe for Bitcoin advocates and coffee aficionados at [stablecoin.myshopify.com](https://stablecoin.myshopify.com).

### Patent Notice

The author reserves all rights to seek patent protection for the novel methods and systems described herein. Public disclosure of this work establishes a priority date of March 12, 2026. Under the America Invents Act, the author retains a one-year grace period from the date of first public disclosure to file patent applications.

**Note to potential filers:** This public repository and its full Git history serve as evidence of prior art. Any patent application covering substantially similar methods filed after the publication date of this repository may be subject to invalidation under 35 U.S.C. 102(a).

## Further Reading

[The Phantom Tollbooth on the Lightning Turnpike](https://stablecoin.myshopify.com/blogs/our-value/the-phantom-tollbooth-on-the-lightning-turnpike) — the full story of how we're monetizing the monetization of AI APIs, and then fading to the background.

## Trademarks

DPYC&trade;, Tollbooth DPYC&trade;, and Don't Pester Your Customer&trade; are trademarks of Lonnie VanZandt. See [TRADEMARKS.md](https://github.com/lonniev/dpyc-community/blob/main/TRADEMARKS.md) in the dpyc-community repository for usage guidelines.

## License

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE) for details.

---

*Because in the end, the tollbooth was never the destination. It was always just the beginning of the journey.*
