import SwiftUI

struct ConstraintParamEditor: View {
    let spec: ConstraintSpec
    let existingParams: [String: AnyCodableValue]?
    let onSave: ([String: AnyCodableValue]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var boolValues: [String: Bool] = [:]
    @State private var daySetValues: [String: Set<Int>] = [:]
    @State private var dateValues: [String: Date] = [:]

    var body: some View {
        NavigationStack {
            Form {
                ForEach(spec.params, id: \.name) { param in
                    Section {
                        paramField(for: param)
                            .accessibilityIdentifier("constraintParamField_\(param.name)")
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
            TextField("HH:MM (24-hour)", text: binding(for: param.name))
                .monospaced()
                .keyboardType(.numbersAndPunctuation)

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

        case .daysOfWeek:
            let days = daySetBinding(for: param.name)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(0..<7, id: \.self) { dayIndex in
                    Toggle(Self.dayLabels[dayIndex], isOn: Binding(
                        get: { days.wrappedValue.contains(dayIndex) },
                        set: { isOn in
                            if isOn { days.wrappedValue.insert(dayIndex) }
                            else { days.wrappedValue.remove(dayIndex) }
                        }
                    ))
                }
            }

        case .date:
            DatePicker(
                param.name.replacingOccurrences(of: "_", with: " ").capitalized,
                selection: dateBinding(for: param.name),
                displayedComponents: .date
            )
            .datePickerStyle(.compact)

        case .picklist:
            Picker(
                param.name.replacingOccurrences(of: "_", with: " ").capitalized,
                selection: binding(for: param.name)
            ) {
                ForEach(param.options ?? [], id: \.self) { option in
                    Text(option.capitalized).tag(option)
                }
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

    private func dateBinding(for key: String) -> Binding<Date> {
        Binding(
            get: { dateValues[key] ?? Date() },
            set: { dateValues[key] = $0 }
        )
    }

    private func daySetBinding(for key: String) -> Binding<Set<Int>> {
        Binding(
            get: { daySetValues[key, default: []] },
            set: { daySetValues[key] = $0 }
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
                if let existing = existingParams?[param.name] {
                    values[param.name] = stringFrom(existing)
                } else if let def = param.defaultValue {
                    values[param.name] = stringFrom(def)
                } else {
                    values[param.name] = ""
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

            case .daysOfWeek:
                if let existing = existingParams?[param.name],
                   case .array(let arr) = existing {
                    daySetValues[param.name] = Set(arr.compactMap { val -> Int? in
                        if case .int(let i) = val { return i }
                        return nil
                    })
                } else if let def = param.defaultValue,
                          case .array(let arr) = def {
                    daySetValues[param.name] = Set(arr.compactMap { val -> Int? in
                        if case .int(let i) = val { return i }
                        return nil
                    })
                } else {
                    daySetValues[param.name] = Set(0...4) // weekdays default
                }

            case .date:
                let isoFormatter = ISO8601DateFormatter()
                isoFormatter.formatOptions = [.withFullDate]
                if let existing = existingParams?[param.name],
                   case .string(let s) = existing,
                   let d = isoFormatter.date(from: s) {
                    dateValues[param.name] = d
                } else {
                    dateValues[param.name] = Date()
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
                let raw = values[param.name, default: ""]
                if !raw.isEmpty {
                    result[param.name] = .string(raw)
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

            case .daysOfWeek:
                let days = daySetValues[param.name, default: []]
                result[param.name] = .array(days.sorted().map { .int($0) })

            case .date:
                if let d = dateValues[param.name] {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd"
                    result[param.name] = .string(formatter.string(from: d))
                }

            case .picklist:
                let raw = values[param.name, default: ""]
                if !raw.isEmpty {
                    result[param.name] = .string(raw)
                }
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
        case .dictionary(let d): return d.description
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

    private static let dayLabels: [String] = [
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
    ]

    private static let commonTimezones: [String] = [
        "America/New_York",
        "America/Chicago",
        "America/Denver",
        "America/Los_Angeles",
        "UTC",
        "Europe/London",
        "Europe/Berlin",
        "Asia/Tokyo",
    ]
}
