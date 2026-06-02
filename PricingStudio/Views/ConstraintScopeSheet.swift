import SwiftUI
import SwiftData

/// Patron audience filter for a single constraint step.  Tool scope is
/// implicit (the chain that owns this step belongs to one tool), so this
/// sheet only narrows the audience to a list of named patron npubs —
/// optional, max 10 per group (clone the constraint for more).
struct ConstraintScopeSheet: View {
    let onSave: (_ patronNpubs: [String]?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Patron.addedAt) private var patrons: [Patron]

    @State private var scopeAllPatrons = true
    @State private var selectedPatronNpubs: Set<String> = []

    var body: some View {
        NavigationStack {
            Form {
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
                    Text("Patron Audience")
                } footer: {
                    if !scopeAllPatrons && !selectedPatronNpubs.isEmpty {
                        Text("\(selectedPatronNpubs.count) patron\(selectedPatronNpubs.count == 1 ? "" : "s") selected")
                    } else if scopeAllPatrons {
                        Text("Constraint applies to every patron calling this tool.")
                    }
                }
            }
            .navigationTitle("Constraint Audience")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") {
                        onSave(nil)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let patronNpubs = scopeAllPatrons ? nil : Array(selectedPatronNpubs)
                        onSave(patronNpubs)
                    }
                }
            }
        }
    }
}
