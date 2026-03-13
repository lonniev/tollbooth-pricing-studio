import Foundation

enum PreviewData {

    static let sampleAuthorityNpub = "npub1d999638gqpn8c594teklxtxva0uvxdng80q3ycyqvldjdl457c7qcrq64z"

    static let sampleOperatorNpub = "npub1y20qa7d3ddmh6730hdr0u0r08zys4p7pyk30uhur9edx4d88q4zqnr3q2h"

    static let sampleMemberRecord = MemberRecord(
        npub: sampleOperatorNpub,
        role: "operator",
        status: "active",
        displayName: "Personal Brain",
        services: [
            MemberService(name: "personal-brain", url: "https://personal-brain.fastmcp.app/mcp", description: "TheBrain knowledge graph access via MCP")
        ],
        upstreamAuthorityNpub: nil,
        memberSince: nil,
        notes: nil
    )

    static let sampleToolPrices: [ToolPrice] = [
        ToolPrice(toolName: "brain_search_thoughts", priceSats: 1, category: "read", intent: "Search thoughts by keyword"),
        ToolPrice(toolName: "brain_get_thought", priceSats: 1, category: "read", intent: "Get a thought by ID"),
        ToolPrice(toolName: "brain_get_thought_graph", priceSats: 1, category: "read", intent: "Get thought connections"),
        ToolPrice(toolName: "brain_brain_query", priceSats: 1, category: "read", intent: "BQL pattern query"),
        ToolPrice(toolName: "brain_create_thought", priceSats: 5, category: "write", intent: "Create a new thought"),
        ToolPrice(toolName: "brain_create_link", priceSats: 5, category: "write", intent: "Link two thoughts"),
        ToolPrice(toolName: "brain_update_thought", priceSats: 5, category: "write", intent: "Update thought metadata"),
        ToolPrice(toolName: "brain_create_or_update_note", priceSats: 5, category: "write", intent: "Create or update a note"),
        ToolPrice(toolName: "brain_morph_thought", priceSats: 10, category: "heavy", intent: "Morph thought type and links"),
        ToolPrice(toolName: "brain_get_thought_graph_paginated", priceSats: 10, category: "heavy", intent: "Paginated graph traversal"),
        ToolPrice(toolName: "brain_session_status", priceSats: 0, category: "auth", intent: "Check session status"),
        ToolPrice(toolName: "brain_check_balance", priceSats: 0, category: "auth", intent: "Check credit balance"),
        ToolPrice(toolName: "brain_how_to_join", priceSats: 0, category: "free", intent: "DPYC onboarding guide"),
        ToolPrice(toolName: "brain_lookup_member", priceSats: 0, category: "free", intent: "Lookup community member"),
    ]

    static let samplePipelineSteps: [PipelineStep] = [
        PipelineStep(
            id: "step-1",
            type: "free_trial",
            params: [
                "seed_sats": .int(50),
                "description": .string("First-time users receive 50 sats to explore")
            ]
        ),
        PipelineStep(
            id: "step-2",
            type: "bulk_bonus",
            params: [
                "threshold_sats": .int(1000),
                "bonus_percent": .int(10),
                "description": .string("10% bonus on purchases over 1000 sats")
            ]
        ),
        PipelineStep(
            id: "step-3",
            type: "loyalty_discount",
            params: [
                "after_purchases": .int(5),
                "discount_percent": .int(5),
                "description": .string("5% discount after 5 purchases")
            ]
        ),
    ]

    static let samplePricingModel = PricingModelResponse(
        status: "ok",
        modelId: "pricing-model-001",
        name: "Personal Brain Standard",
        isActive: true,
        tools: sampleToolPrices,
        pipeline: samplePipelineSteps
    )

    static let sampleOperatorStats = OperatorStats(
        registryRole: "operator",
        registryStatus: "active",
        registryDisplayName: "Personal Brain",
        services: [
            MemberService(name: "personal-brain", url: "https://personal-brain.fastmcp.app/mcp", description: "TheBrain knowledge graph access via MCP")
        ],
        totalToolCount: sampleToolPrices.count,
        freeToolCount: sampleToolPrices.filter { $0.priceSats == 0 }.count,
        paidToolCount: sampleToolPrices.filter { $0.priceSats > 0 }.count,
        categorySummaries: {
            let grouped = Dictionary(grouping: sampleToolPrices, by: \.category)
            return ["free", "auth", "read", "write", "heavy"].compactMap { cat in
                guard let tools = grouped[cat] else { return nil }
                let prices = tools.map(\.priceSats)
                return ToolCategorySummary(
                    category: cat,
                    count: tools.count,
                    minPriceSats: prices.min() ?? 0,
                    maxPriceSats: prices.max() ?? 0
                )
            }
        }(),
        fetchedAt: Date()
    )

    static let emptyPricingModel = PricingModelResponse(
        status: "no_pricing_model",
        modelId: nil,
        name: nil,
        isActive: nil,
        tools: nil,
        pipeline: nil
    )
}
