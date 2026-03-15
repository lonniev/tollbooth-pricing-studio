import SwiftUI

struct ConstraintParamEditor: View {
    let spec: ConstraintSpec
    let existingParams: [String: AnyCodableValue]?
    let onSave: ([String: AnyCodableValue]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var boolValues: [String: Bool] = [:]

    var body: some View {
        NavigationStack {
            Form {
                ForEach(spec.params, id: \.name) { param in
                    Section {
                        paramField(for: param)
                    } header: {
                        Text(param.name.replacingOccurrences(of: "_", with: " ").capitalized)
                    } footer: {
                        Text(param.description)
                            .font(.caption2)
                    }
                }
            }
            .navigationTitle(spec.type.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(buildParams())
                        dismiss()
                    }
                }
            }
            .onAppear { initializeValues() }
        }
    }

    // MARK: - Dynamic Field Rendering

    @ViewBuilder
    private func paramField(for param: ParamSpec) -> some View {
        switch param.type {
        case .int:
            TextField("0", text: binding(for: param.name))
                .keyboardType(.numberPad)
                .monospaced()

        case .float:
            TextField("0.0", text: binding(for: param.name))
                .keyboardType(.decimalPad)
                .monospaced()

        case .string:
            TextField("Value", text: binding(for: param.name))

        case .bool:
            Toggle(
                param.name.replacingOccurrences(of: "_", with: " ").capitalized,
                isOn: boolBinding(for: param.name)
            )

        case .schedule:
            VStack(alignment: .leading, spacing: 8) {
                Text("Start")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("HH:mm or cron expression", text: binding(for: "\(param.name)_start"))
                    .monospaced()
                Text("End")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("HH:mm or cron expression", text: binding(for: "\(param.name)_end"))
                    .monospaced()
            }

        case .timezone:
            Picker(
                "Timezone",
                selection: binding(for: param.name)
            ) {
                ForEach(Self.commonTimezones, id: \.self) { tz in
                    Text(tz).tag(tz)
                }
            }

        case .tiers:
            VStack(alignment: .leading, spacing: 4) {
                Text("JSON array of tier objects")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: binding(for: param.name))
                    .monospaced()
                    .font(.callout)
                    .frame(minHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
            }
        }
    }

    // MARK: - Bindings

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { values[key, default: ""] },
            set: { values[key] = $0 }
        )
    }

    private func boolBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { boolValues[key, default: false] },
            set: { boolValues[key] = $0 }
        )
    }

    // MARK: - Initialization

    private func initializeValues() {
        for param in spec.params {
            switch param.type {
            case .bool:
                if let existing = existingParams?[param.name] {
                    boolValues[param.name] = boolFrom(existing)
                } else if let def = param.defaultValue {
                    boolValues[param.name] = boolFrom(def)
                } else {
                    boolValues[param.name] = false
                }

            case .schedule:
                if let existing = existingParams?[param.name],
                   case .string(let s) = existing {
                    // Expect "start|end" format stored as a single string
                    let parts = s.split(separator: "|", maxSplits: 1)
                    values["\(param.name)_start"] = parts.count > 0 ? String(parts[0]) : ""
                    values["\(param.name)_end"] = parts.count > 1 ? String(parts[1]) : ""
                } else if let existing = existingParams {
                    // Also support separate start/end keys in the params dict
                    if let startVal = existing["\(param.name)_start"] {
                        values["\(param.name)_start"] = stringFrom(startVal)
                    }
                    if let endVal = existing["\(param.name)_end"] {
                        values["\(param.name)_end"] = stringFrom(endVal)
                    }
                }
                if values["\(param.name)_start"] == nil {
                    values["\(param.name)_start"] = ""
                }
                if values["\(param.name)_end"] == nil {
                    values["\(param.name)_end"] = ""
                }

            case .tiers:
                if let existing = existingParams?[param.name],
                   case .array(let arr) = existing {
                    // Pretty-print the array description
                    values[param.name] = "[\(arr.map(\.description).joined(separator: ", "))]"
                } else if let def = param.defaultValue {
                    values[param.name] = stringFrom(def)
                } else {
                    values[param.name] = "[]"
                }

            default:
                if let existing = existingParams?[param.name] {
                    values[param.name] = stringFrom(existing)
                } else if let def = param.defaultValue {
                    values[param.name] = stringFrom(def)
                } else {
                    values[param.name] = ""
                }
            }
        }
    }

    // MARK: - Build Output

    private func buildParams() -> [String: AnyCodableValue] {
        var result: [String: AnyCodableValue] = [:]

        for param in spec.params {
            switch param.type {
            case .int:
                let raw = values[param.name, default: ""]
                if let intVal = Int(raw) {
                    result[param.name] = .int(intVal)
                }

            case .float:
                let raw = values[param.name, default: ""]
                if let doubleVal = Double(raw) {
                    result[param.name] = .double(doubleVal)
                }

            case .string:
                let raw = values[param.name, default: ""]
                if !raw.isEmpty {
                    result[param.name] = .string(raw)
                }

            case .bool:
                result[param.name] = .bool(boolValues[param.name, default: false])

            case .schedule:
                let start = values["\(param.name)_start", default: ""]
                let end = values["\(param.name)_end", default: ""]
                if !start.isEmpty || !end.isEmpty {
                    result["\(param.name)_start"] = .string(start)
                    result["\(param.name)_end"] = .string(end)
                }

            case .timezone:
                let raw = values[param.name, default: ""]
                if !raw.isEmpty {
                    result[param.name] = .string(raw)
                }

            case .tiers:
                let raw = values[param.name, default: "[]"]
                // Store as raw string; the server will parse the JSON
                result[param.name] = .string(raw)
            }
        }

        return result
    }

    // MARK: - Helpers

    private func stringFrom(_ value: AnyCodableValue) -> String {
        switch value {
        case .string(let s): return s
        case .int(let i): return "\(i)"
        case .double(let d): return "\(d)"
        case .bool(let b): return b ? "true" : "false"
        case .array(let a): return "[\(a.map(\.description).joined(separator: ", "))]"
        case .null: return ""
        }
    }

    private func boolFrom(_ value: AnyCodableValue) -> Bool {
        switch value {
        case .bool(let b): return b
        case .string(let s): return s.lowercased() == "true" || s == "1"
        case .int(let i): return i != 0
        default: return false
        }
    }

    // MARK: - Constants

    private static let commonTimezones: [String] = [
        "US/Eastern",
        "US/Central",
        "US/Mountain",
        "US/Pacific",
        "UTC",
        "Europe/London",
        "Europe/Berlin",
        "Asia/Tokyo",
    ]
}
