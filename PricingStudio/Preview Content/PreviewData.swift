import Foundation

/// Generic preview data for SwiftUI canvas — not coupled to any real operator.
enum PreviewData {

    static let sampleAuthorityNpub = "npub1sample0authority000000000000000000000000000000000000000000"

    static let sampleOperatorNpub = "npub1sample0operator0000000000000000000000000000000000000000000"

    static let sampleMemberRecord = MemberRecord(
        npub: sampleOperatorNpub,
        role: "operator",
        status: "active",
        displayName: "Acme Weather",
        services: [
            MemberService(name: "acme-weather", url: "https://acme-weather.fastmcp.app/mcp", description: "Weather forecasts and historical data via MCP")
        ],
        upstreamAuthorityNpub: sampleAuthorityNpub,
        memberSince: nil,
        notes: nil
    )

    static let sampleToolPrices: [ToolPrice] = [
        // Read tier (1 sat)
        ToolPrice(toolId: ToolPrice.capabilityUUID("weather_current"), toolName: "weather_current", priceSats: 1, category: "read", intent: "Current conditions"),
        ToolPrice(toolId: ToolPrice.capabilityUUID("weather_forecast"), toolName: "weather_forecast", priceSats: 1, category: "read", intent: "Multi-day forecast"),
        // Write tier (5 sats)
        ToolPrice(toolId: ToolPrice.capabilityUUID("weather_subscribe"), toolName: "weather_subscribe", priceSats: 5, category: "write", intent: "Subscribe to alerts"),
        ToolPrice(toolId: ToolPrice.capabilityUUID("weather_set_location"), toolName: "weather_set_location", priceSats: 5, category: "write", intent: "Set default location"),
        // Heavy tier (10 sats)
        ToolPrice(toolId: ToolPrice.capabilityUUID("weather_historical"), toolName: "weather_historical", priceSats: 10, category: "heavy", intent: "Historical archive query"),
        ToolPrice(toolId: ToolPrice.capabilityUUID("weather_bulk_export"), toolName: "weather_bulk_export", priceSats: 10, category: "heavy", intent: "Bulk CSV export"),
        // Free tools
        ToolPrice(toolId: ToolPrice.capabilityUUID("weather_check_balance"), toolName: "weather_check_balance", priceSats: 0, category: "auth", intent: "Check credit balance"),
        ToolPrice(toolId: ToolPrice.capabilityUUID("weather_service_status"), toolName: "weather_service_status", priceSats: 0, category: "free", intent: "Health check"),
        ToolPrice(toolId: ToolPrice.capabilityUUID("weather_how_to_join"), toolName: "weather_how_to_join", priceSats: 0, category: "free", intent: "DPYC onboarding guide"),
    ]

    static let samplePipelineSteps: [PipelineStep] = [
        .create(type: "free_trial", params: [
            "seed_sats": .int(50),
            "description": .string("First-time users receive 50 sats to explore"),
        ]),
        .create(type: "bulk_bonus", params: [
            "threshold_sats": .int(1000),
            "bonus_percent": .int(10),
            "description": .string("10% bonus on purchases over 1000 sats"),
        ]),
        .create(type: "loyalty_discount", params: [
            "after_purchases": .int(5),
            "discount_percent": .int(5),
            "description": .string("5% discount after 5 purchases"),
        ]),
    ]

    static let samplePricingModel = PricingModelResponse(
        status: "ok",
        modelId: "pricing-model-001",
        name: "Acme Weather Standard",
        isActive: true,
        tools: sampleToolPrices,
        pipeline: samplePipelineSteps,
        trancheLifetime: .default
    )

    static let sampleOperatorStats = OperatorStats(
        registryRole: "operator",
        registryStatus: "active",
        registryDisplayName: "Acme Weather",
        services: [
            MemberService(name: "acme-weather", url: "https://acme-weather.fastmcp.app/mcp", description: "Weather forecasts and historical data via MCP")
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
        versions: nil,
        fetchedAt: Date()
    )

    static let emptyPricingModel = PricingModelResponse(
        status: "no_pricing_model",
        modelId: nil,
        name: nil,
        isActive: nil,
        tools: nil,
        pipeline: nil,
        trancheLifetime: nil
    )
}
