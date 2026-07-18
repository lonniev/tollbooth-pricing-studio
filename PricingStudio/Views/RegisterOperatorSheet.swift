import SwiftUI
import SwiftData

/// Inline operator registration / re-registration / Authority-switch sheet.
///
/// Performs the immediate-consent `register_operator` flow (Authority-side).
/// For the operator-initiated *deferred courtship* (`request_adoption` → the
/// Authority owner's Pending Adoptions queue) see `SeekAdoptionSheet`.
///
/// Three cases, all handled by the same Form:
///   1. Operator has no current Authority — straight register flow.
///   2. Operator is registered with A and user picks A again —
///      treated as re-register (no deregister call).
///   3. Operator is registered with A and user picks B —
///      deregister(A) is attempted first, then register(B). A failure
///      on the deregister step does NOT block the register; the user
///      gets a warning that A's registry record may be stale.
struct RegisterOperatorSheet: View {
    let operatorTarget: any PricingTarget
    @Bindable var pricingVM: PricingViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Authority.addedAt) private var authorities: [Authority]
    @State private var selectedAuthority: Authority?
    @State private var status: AdoptionStatus = .idle
    @State private var deregisterWarning: String?

    enum AdoptionStatus: Equatable {
        case idle
        case deregistering
        case registering
        case success(String)
        case failed(String)

        static func == (lhs: AdoptionStatus, rhs: AdoptionStatus) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle),
                 (.deregistering, .deregistering),
                 (.registering, .registering): return true
            case (.success(let a), .success(let b)): return a == b
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    private var isSuccess: Bool {
        if case .success = status { return true }
        return false
    }

    private var inFlight: Bool {
        status == .deregistering || status == .registering
    }

    private var currentAuthority: Authority? {
        guard let op = operatorTarget as? Operator,
              let authNpub = op.authorityNpub else { return nil }
        return authorities.first(where: { $0.npub == authNpub })
    }

    private var isSwitching: Bool {
        guard let cur = currentAuthority, let sel = selectedAuthority else { return false }
        return cur.npub != sel.npub
    }

    private var sheetTitle: String {
        if isSuccess { return "Registered" }
        return currentAuthority == nil ? "Register Operator" : "Switch Authority"
    }

    private var confirmLabel: String {
        if currentAuthority == nil { return "Request" }
        return isSwitching ? "Switch" : "Re-register"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(operatorTarget.displayName)
                            .font(.headline)
                        Text(operatorTarget.npub)
                            .font(.caption)
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Operator")
                }

                if let cur = currentAuthority {
                    Section {
                        HStack {
                            Text(cur.displayName)
                                .font(.subheadline)
                            Spacer()
                            Text(String(cur.npub.prefix(20)) + "…")
                                .font(.caption)
                                .monospaced()
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Currently registered with")
                    } footer: {
                        Text("Picking a different Authority below will deregister the operator from \(cur.displayName) first, then register with the new Authority. Picking the same Authority re-runs registration.")
                    }
                }

                Section {
                    if authorities.isEmpty {
                        Text("No Authorities added yet. Add an Authority first.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(authorities) { auth in
                            Button {
                                selectedAuthority = auth
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(auth.displayName)
                                            .font(.subheadline)
                                        Text(String(auth.npub.prefix(20)) + "…")
                                            .font(.caption)
                                            .monospaced()
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selectedAuthority?.npub == auth.npub {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text(currentAuthority == nil
                         ? "Choose an Authority to adopt this Operator"
                         : "Choose a target Authority")
                }

                if case .deregistering = status {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Deregistering from \(currentAuthority?.displayName ?? "current Authority")…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if case .registering = status {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Requesting adoption…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if case .success = status {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Registered", systemImage: "checkmark.circle.fill")
                                .font(.headline)
                                .foregroundStyle(.green)
                            Text("**\(operatorTarget.displayName)** is now registered with **\(selectedAuthority?.displayName ?? "Authority")**.")
                                .font(.subheadline)
                            Text("The operator can now purchase credits and serve toll calls.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let warning = deregisterWarning {
                                Divider()
                                Label("Old Authority cleanup", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text(warning)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if case .failed(let error) = status {
                    Section {
                        Label("Request failed", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(sheetTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isSuccess {
                        Button("Done") { dismiss() }
                    } else {
                        Button("Cancel") { dismiss() }
                    }
                }
                if !isSuccess {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(confirmLabel) {
                            guard let auth = selectedAuthority else { return }
                            Task { await runFlow(target: auth) }
                        }
                        .disabled(selectedAuthority == nil || inFlight)
                    }
                }
            }
            .onAppear {
                selectedAuthority = currentAuthority
            }
        }
    }

    /// Orchestrates deregister-then-register when the user picks a different
    /// Authority, or just register otherwise. A deregister failure does not
    /// block the register step — it surfaces as a warning so the user can
    /// hand-clean the old Authority's registry record.
    private func runFlow(target: Authority) async {
        deregisterWarning = nil

        if let cur = currentAuthority, cur.npub != target.npub {
            status = .deregistering
            if let cause = await tryDeregister(from: cur) {
                deregisterWarning = "Could not deregister from \(cur.displayName): \(cause). The old registry entry may need manual cleanup."
            }
        }

        await register(with: target)
    }

    /// Returns nil on clean success, or an error string on failure (caller
    /// converts to a non-blocking warning).
    private func tryDeregister(from authority: Authority) async -> String? {
        guard let endpointString = authority.mcpEndpointURL,
              let endpointURL = URL(string: endpointString) else {
            return "Authority has no MCP endpoint"
        }
        let mcpService = MCPService()
        do {
            _ = try await mcpService.callDeregisterOperator(
                endpointURL: endpointURL,
                operatorNpub: operatorTarget.npub,
                authorityNpub: authority.npub
            )
            if let op = operatorTarget as? Operator {
                op.authorityNpub = nil
                try? modelContext.save()
            }
            return nil
        } catch let MCPError.structuredError(code, _, _) {
            return code
        } catch {
            return error.localizedDescription
        }
    }

    private func register(with authority: Authority) async {
        guard let endpointString = authority.mcpEndpointURL,
              let endpointURL = URL(string: endpointString) else {
            status = .failed("Authority has no MCP endpoint")
            return
        }

        status = .registering
        let mcpService = MCPService()

        do {
            let result = try await mcpService.callRegisterOperator(
                endpointURL: endpointURL,
                operatorNpub: operatorTarget.npub,
                operatorServiceURL: (operatorTarget as? Operator)?.mcpEndpointURL ?? "",
                displayName: operatorTarget.displayName,
                authorityNpub: authority.npub
            )

            if let op = operatorTarget as? Operator {
                op.authorityNpub = authority.npub
                try? modelContext.save()
            }

            status = .success(result)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
