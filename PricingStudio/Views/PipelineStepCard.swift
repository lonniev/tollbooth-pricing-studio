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
                                Text(value.description)
                                    .font(.caption.monospaced())
                            }
                        }
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

    private var sortedParams: [(key: String, value: AnyCodableValue)] {
        // Put description first, then alphabetical
        let pairs = step.params.map { (key: $0.key, value: $0.value) }
        return pairs.sorted { a, b in
            if a.key == "description" { return true }
            if b.key == "description" { return false }
            return a.key < b.key
        }
    }

    private func formatParamKey(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ").capitalized + ":"
    }
}
