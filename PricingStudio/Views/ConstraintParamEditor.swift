import SwiftUI

struct ConstraintParamEditor: View {
    let spec: ConstraintSpec
    let existingParams: [String: AnyCodableValue]?
    let onSave: ([String: AnyCodableValue]) -> Void
    /// Optional — feeds the `.couponPicker` ParamType.  Nil when the
    /// editor is opened from a context without coupon CRUD wired up.
    var couponViewModel: CouponViewModel? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var boolValues: [String: Bool] = [:]
    @State private var daySetValues: [String: Set<Int>] = [:]
    @State private var dateValues: [String: Date] = [:]
    @State private var tierRows: [String: [[String: String]]] = [:]

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
            tierEditor(for: param)

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

        case .couponPicker:
            couponPickerField(for: param)
        }
    }

    @ViewBuilder
    private func couponPickerField(for param: ParamSpec) -> some View {
        if let vm = couponViewModel {
            let pickable = vm.pickableCoupons
            if pickable.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No coupons to pick yet.")
                        .font(.subheadline)
                    Text("Mint a coupon in this operator's Coupons screen, then return here to attach it to this tool's chain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Picker(
                    param.name.replacingOccurrences(of: "_", with: " ").capitalized,
                    selection: binding(for: param.name),
                ) {
                    Text("Select a coupon…").tag("")
                    ForEach(pickable) { coupon in
                        Text("\(coupon.name) — \(Int(coupon.discountPercent))% off").tag(coupon.id)
                    }
                }
            }
        } else {
            // Degraded mode — operator can still paste a UUID, but the
            // CRUD screen is the supported flow.  Surface that.
            VStack(alignment: .leading, spacing: 6) {
                TextField("coupon UUID", text: binding(for: param.name))
                    .monospaced()
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                Text("Coupon picker isn't wired up here. Paste a coupon UUID, or attach this constraint from the Pricing detail view where the coupon list is available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Tier Editor

    @ViewBuilder
    private func tierEditor(for param: ParamSpec) -> some View {
        let fields = param.tierFields ?? []
        let rows = tierRowsBinding(for: param.name)

        VStack(alignment: .leading, spacing: 8) {
            // Column headers
            if !fields.isEmpty {
                HStack(spacing: 8) {
                    ForEach(fields, id: \.name) { field in
                        Text(field.label)
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Space for delete button
                    Color.clear.frame(width: 28)
                }
                .padding(.horizontal, 4)
            }

            // Tier rows
            ForEach(Array(rows.wrappedValue.indices), id: \.self) { rowIndex in
                HStack(spacing: 8) {
                    ForEach(fields, id: \.name) { field in
                        TextField(field.placeholder, text: Binding(
                            get: { rows.wrappedValue[rowIndex][field.name, default: ""] },
                            set: { rows.wrappedValue[rowIndex][field.name] = $0 }
                        ))
                        .keyboardType(field.type == .int ? .numberPad : .decimalPad)
                        .monospaced()
                        .font(.callout)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                    }

                    Button(role: .destructive) {
                        rows.wrappedValue.remove(at: rowIndex)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 28)
                }
            }

            // Add tier button
            Button {
                var newRow: [String: String] = [:]
                for field in fields {
                    newRow[field.name] = ""
                }
                rows.wrappedValue.append(newRow)
            } label: {
                Label("Add Tier", systemImage: "plus.circle")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func tierRowsBinding(for key: String) -> Binding<[[String: String]]> {
        Binding(
            get: { tierRows[key, default: []] },
            set: { tierRows[key] = $0 }
        )
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
                let source: AnyCodableValue? = existingParams?[param.name] ?? param.defaultValue
                if let source, case .array(let arr) = source {
                    tierRows[param.name] = arr.compactMap { item -> [String: String]? in
                        guard case .dictionary(let dict) = item else { return nil }
                        var row: [String: String] = [:]
                        for (k, v) in dict {
                            row[k] = stringFrom(v)
                        }
                        return row
                    }
                } else {
                    tierRows[param.name] = []
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
                let rows = tierRows[param.name, default: []]
                let fields = param.tierFields ?? []
                let arr: [AnyCodableValue] = rows.compactMap { row in
                    var dict: [String: AnyCodableValue] = [:]
                    for field in fields {
                        let raw = row[field.name, default: ""]
                        guard !raw.isEmpty else { continue }
                        switch field.type {
                        case .int:
                            if let v = Int(raw) { dict[field.name] = .int(v) }
                        case .float:
                            if let v = Double(raw) { dict[field.name] = .double(v) }
                        default:
                            dict[field.name] = .string(raw)
                        }
                    }
                    return dict.isEmpty ? nil : .dictionary(dict)
                }
                result[param.name] = .array(arr)

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

            case .couponPicker:
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
