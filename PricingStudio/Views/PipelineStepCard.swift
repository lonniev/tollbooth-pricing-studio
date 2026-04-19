import SwiftUI

struct PipelineStepCard: View {
    let step: PipelineStep

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: step.displayType.iconName)
                    .foregroundStyle(.tint)
                    .imageScale(.large)

                Text(step.displayType.displayName)
                    .font(.headline)
            }

            if !step.params.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(sortedParams, id: \.key) { key, value in
                        if key == "description" {
                            Text(value.description)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: 4) {
                                Text(formatParamKey(key))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(formatParamValue(key, value))
                                    .font(.caption.monospaced())
                            }
                        }
                    }
                }
            }

            if step.isScoped {
                Divider()
                HStack(spacing: 12) {
                    if let tools = step.toolIds, !tools.isEmpty {
                        Label("\(tools.count) tool\(tools.count == 1 ? "" : "s")", systemImage: "wrench")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                    if let patrons = step.patronNpubs, !patrons.isEmpty {
                        Label("\(patrons.count) patron\(patrons.count == 1 ? "" : "s")", systemImage: "person")
                            .font(.caption2)
                            .foregroundStyle(.purple)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    /// Legacy param keys that should never display — remnants of old data formats.
    private static let hiddenParams: Set<String> = [
        "schedule",           // legacy concatenated HH:MM-HH:MM
        "schedule_start",     // renamed to in_effect
        "schedule_end",       // renamed to until
        "discount_percent",   // renamed to percent_off
        "discount_sats",      // renamed to max_discount
        "repeats_when",       // renamed to repeats
        "starts_on",          // renamed to apply_on
    ]

    private var sortedParams: [(key: String, value: AnyCodableValue)] {
        // Use catalog param order if available; filter out legacy keys
        let spec = ConstraintCatalog.spec(for: step.displayType)
        let catalogOrder = spec?.params.map(\.name) ?? []
        let pairs = step.params
            .filter { !Self.hiddenParams.contains($0.key) }
            .map { (key: $0.key, value: $0.value) }

        if catalogOrder.isEmpty {
            return pairs.sorted { a, b in
                if a.key == "description" { return true }
                if b.key == "description" { return false }
                return a.key < b.key
            }
        }

        return pairs.sorted { a, b in
            let ai = catalogOrder.firstIndex(of: a.key) ?? Int.max
            let bi = catalogOrder.firstIndex(of: b.key) ?? Int.max
            return ai < bi
        }
    }

    private func formatParamKey(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ").capitalized + ":"
    }

    private static let dayNames = [
        "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun",
    ]

    private func formatParamValue(_ key: String, _ value: AnyCodableValue) -> String {
        if key == "days_of_week", case .array(let items) = value {
            let names = items.compactMap { item -> String? in
                if case .int(let idx) = item, idx >= 0, idx < Self.dayNames.count {
                    return Self.dayNames[idx]
                }
                return nil
            }
            return names.isEmpty ? value.description : names.joined(separator: ", ")
        }
        return value.description
    }
}
