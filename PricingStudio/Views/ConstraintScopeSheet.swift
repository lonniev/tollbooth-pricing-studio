import SwiftUI
import SwiftData

/// Lets the operator choose which tools and patrons a constraint applies to.
struct ConstraintScopeSheet: View {
    let tools: [ToolPrice]
    let onSave: (_ toolIds: [String]?, _ patronNpubs: [String]?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Patron.addedAt) private var patrons: [Patron]

    @State private var scopeAllTools = true
    @State private var selectedToolIds: Set<String> = []
    @State private var scopeAllPatrons = true
    @State private var selectedPatronNpubs: Set<String> = []

    var body: some View {
        NavigationStack {
            Form {
                Section("Tool Scope") {
                    Toggle("All tools", isOn: $scopeAllTools)
                    if !scopeAllTools {
                        ForEach(tools) { tool in
                            Toggle(isOn: Binding(
                                get: { selectedToolIds.contains(tool.toolId) },
                                set: { on in
                                    if on { selectedToolIds.insert(tool.toolId) }
                                    else { selectedToolIds.remove(tool.toolId) }
                                }
                            )) {
                                VStack(alignment: .leading) {
                                    Text(tool.toolName)
                                        .font(.subheadline)
                                    Text(tool.category)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section {
                    Toggle("All patrons", isOn: $scopeAllPatrons)
                    if !scopeAllPatrons {
                        if patrons.isEmpty {
                            Text("No patrons registered")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(patrons.prefix(10)) { patron in
                                Toggle(isOn: Binding(
                                    get: { selectedPatronNpubs.contains(patron.npub) },
                                    set: { on in
                                        if on { selectedPatronNpubs.insert(patron.npub) }
                                        else { selectedPatronNpubs.remove(patron.npub) }
                                    }
                                )) {
                                    VStack(alignment: .leading) {
                                        Text(patron.displayName)
                                            .font(.subheadline)
                                        Text(String(patron.npub.prefix(20)) + "…")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .monospaced()
                                    }
                                }
                            }
                            if patrons.count > 10 {
                                Text("Max 10 patrons per constraint. Clone for more.")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                } header: {
                    Text("Patron Scope")
                } footer: {
                    if !scopeAllPatrons && !selectedPatronNpubs.isEmpty {
                        Text("\(selectedPatronNpubs.count) patron\(selectedPatronNpubs.count == 1 ? "" : "s") selected")
                    }
                }
            }
            .navigationTitle("Constraint Scope")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") {
                        onSave(nil, nil)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let toolIds = scopeAllTools ? nil : Array(selectedToolIds)
                        let patronNpubs = scopeAllPatrons ? nil : Array(selectedPatronNpubs)
                        onSave(toolIds, patronNpubs)
                    }
                }
            }
        }
    }
}
