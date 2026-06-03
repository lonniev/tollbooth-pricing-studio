import SwiftUI

/// Operator-side Coupons CRUD screen.
///
/// Reached from the Pricing detail view.  Lists this operator's
/// coupons with a progress chip per row, lets the operator mint new
/// ones, edit caps + window, and delete (cascades to redemptions).
struct CouponsView: View {
    let endpointURL: URL
    let operatorNpub: String

    @Bindable var viewModel: CouponViewModel

    @State private var showingMintSheet = false
    @State private var pendingDelete: Coupon?
    @State private var editingCoupon: Coupon?

    var body: some View {
        Group {
            switch viewModel.loadState {
            case .idle:
                LoadingQuoteView()
                    .onAppear { viewModel.refresh(endpointURL: endpointURL, operatorNpub: operatorNpub) }
            case .loading:
                LoadingQuoteView()
            case .error(let msg):
                ContentUnavailableView(
                    "Couldn't load coupons",
                    systemImage: "exclamationmark.triangle",
                    description: Text(msg),
                )
            case .loaded:
                if viewModel.coupons.isEmpty {
                    emptyState
                } else {
                    couponList
                }
            }
        }
        .navigationTitle("Coupons")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingMintSheet = true
                } label: {
                    Label("Mint", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    viewModel.refresh(endpointURL: endpointURL, operatorNpub: operatorNpub)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .sheet(isPresented: $showingMintSheet) {
            MintCouponSheet(
                endpointURL: endpointURL,
                operatorNpub: operatorNpub,
                viewModel: viewModel,
            )
        }
        .sheet(item: $editingCoupon) { coupon in
            EditCouponSheet(
                endpointURL: endpointURL,
                operatorNpub: operatorNpub,
                viewModel: viewModel,
                coupon: coupon,
            )
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "coupon")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } },
            ),
            titleVisibility: .visible,
            presenting: pendingDelete,
        ) { coupon in
            Button("🗑 Delete", role: .destructive) {
                Task {
                    try? await viewModel.delete(
                        endpointURL: endpointURL,
                        operatorNpub: operatorNpub,
                        couponId: coupon.id,
                    )
                    pendingDelete = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("This also clears every patron's redemption of this coupon. Patrons can't undo it.")
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No coupons yet", systemImage: "ticket")
        } description: {
            Text("Mint a coupon with a catchy name. Share the code via Twitter, email, or DM — patrons redeem once and the discount applies automatically.")
        } actions: {
            Button("Mint coupon") { showingMintSheet = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var couponList: some View {
        List {
            ForEach(viewModel.coupons) { coupon in
                CouponRow(coupon: coupon)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            pendingDelete = coupon
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            editingCoupon = coupon
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                    .contextMenu {
                        Button("Edit") { editingCoupon = coupon }
                        Button("Delete", role: .destructive) { pendingDelete = coupon }
                    }
                    .accessibilityIdentifier("couponRow_\(coupon.name)")
            }
        }
    }
}

// MARK: - Coupon row

private struct CouponRow: View {
    let coupon: Coupon

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(coupon.name)
                    .font(.headline)
                Spacer()
                Text("\(Int(coupon.discountPercent))% off")
                    .font(.subheadline.bold())
                    .foregroundStyle(.tint)
            }

            HStack(spacing: 12) {
                Label(coupon.status().displayLabel, systemImage: statusIcon)
                    .font(.caption)
                    .foregroundStyle(statusColor)

                Text("Until \(coupon.validUntil.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let upp = coupon.usesPerPatron {
                    Text("\(upp)× per patron")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("∞ per patron")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Text(coupon.progressLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let fraction = coupon.progressFraction {
                    ProgressView(value: fraction)
                        .frame(maxWidth: 140)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var statusIcon: String {
        switch coupon.status() {
        case .active: "checkmark.circle.fill"
        case .notYetActive: "clock.fill"
        case .expired: "calendar.badge.exclamationmark"
        case .totalClaimed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch coupon.status() {
        case .active: .green
        case .notYetActive: .blue
        case .expired: .secondary
        case .totalClaimed: .orange
        }
    }
}

// MARK: - Mint sheet

private struct MintCouponSheet: View {
    let endpointURL: URL
    let operatorNpub: String
    @Bindable var viewModel: CouponViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var discountPercent: Double = 25
    @State private var validFrom: Date = .now
    @State private var validUntil: Date = Calendar.current.date(byAdding: .day, value: 30, to: .now)!
    @State private var unlimitedPerPatron = false
    @State private var usesPerPatron: Int = 1
    @State private var unlimitedTotal = true
    @State private var totalUses: Int = 100
    @State private var submitting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Code") {
                    TextField("FRESHMAN, EARLYBIRD, …", text: $name)
                        .textInputAutocapitalization(.characters)
                        .disableAutocorrection(true)
                }

                Section("Discount") {
                    HStack {
                        Slider(value: $discountPercent, in: 1...100, step: 1)
                        Text("\(Int(discountPercent))%")
                            .font(.body.monospacedDigit())
                            .frame(width: 56, alignment: .trailing)
                    }
                }

                Section("Window") {
                    DatePicker("Active from", selection: $validFrom, displayedComponents: [.date])
                    DatePicker("Active until", selection: $validUntil, displayedComponents: [.date])
                }

                Section("Per-patron cap") {
                    Toggle("Unlimited per patron", isOn: $unlimitedPerPatron)
                    if !unlimitedPerPatron {
                        Stepper(value: $usesPerPatron, in: 1...999) {
                            Text("\(usesPerPatron) use\(usesPerPatron == 1 ? "" : "s") per patron")
                        }
                    }
                }

                Section("Total cap") {
                    Toggle("Unlimited total", isOn: $unlimitedTotal)
                    if !unlimitedTotal {
                        Stepper(value: $totalUses, in: 1...100_000) {
                            Text("\(totalUses) total uses")
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Mint coupon")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(submitting ? "Minting…" : "Mint") { submit() }
                        .disabled(submitting || name.trimmingCharacters(in: .whitespaces).isEmpty || validUntil <= validFrom)
                }
            }
        }
    }

    private func submit() {
        submitting = true
        errorMessage = nil
        Task {
            do {
                _ = try await viewModel.mint(
                    endpointURL: endpointURL,
                    operatorNpub: operatorNpub,
                    name: name.trimmingCharacters(in: .whitespaces),
                    discountPercent: discountPercent,
                    validFrom: validFrom,
                    validUntil: validUntil,
                    usesPerPatron: unlimitedPerPatron ? nil : usesPerPatron,
                    totalUses: unlimitedTotal ? nil : totalUses,
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                submitting = false
            }
        }
    }
}

// MARK: - Edit sheet

private struct EditCouponSheet: View {
    let endpointURL: URL
    let operatorNpub: String
    @Bindable var viewModel: CouponViewModel
    let coupon: Coupon
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var discountPercent: Double
    @State private var validFrom: Date
    @State private var validUntil: Date
    @State private var unlimitedPerPatron: Bool
    @State private var usesPerPatron: Int
    @State private var unlimitedTotal: Bool
    @State private var totalUses: Int
    @State private var submitting = false
    @State private var errorMessage: String?

    init(
        endpointURL: URL, operatorNpub: String,
        viewModel: CouponViewModel, coupon: Coupon,
    ) {
        self.endpointURL = endpointURL
        self.operatorNpub = operatorNpub
        self.viewModel = viewModel
        self.coupon = coupon
        _name = State(initialValue: coupon.name)
        _discountPercent = State(initialValue: coupon.discountPercent)
        _validFrom = State(initialValue: coupon.validFrom)
        _validUntil = State(initialValue: coupon.validUntil)
        _unlimitedPerPatron = State(initialValue: coupon.usesPerPatron == nil)
        _usesPerPatron = State(initialValue: coupon.usesPerPatron ?? 1)
        _unlimitedTotal = State(initialValue: coupon.totalUses == nil)
        _totalUses = State(initialValue: coupon.totalUses ?? 100)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Code") {
                    TextField("Coupon name", text: $name)
                        .textInputAutocapitalization(.characters)
                        .disableAutocorrection(true)
                }
                Section("Discount") {
                    HStack {
                        Slider(value: $discountPercent, in: 1...100, step: 1)
                        Text("\(Int(discountPercent))%")
                            .font(.body.monospacedDigit())
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                Section("Window") {
                    DatePicker("Active from", selection: $validFrom, displayedComponents: [.date])
                    DatePicker("Active until", selection: $validUntil, displayedComponents: [.date])
                }
                Section("Per-patron cap") {
                    Toggle("Unlimited per patron", isOn: $unlimitedPerPatron)
                    if !unlimitedPerPatron {
                        Stepper(value: $usesPerPatron, in: 1...999) {
                            Text("\(usesPerPatron) use\(usesPerPatron == 1 ? "" : "s") per patron")
                        }
                    }
                }
                Section("Total cap") {
                    Toggle("Unlimited total", isOn: $unlimitedTotal)
                    if !unlimitedTotal {
                        Stepper(value: $totalUses, in: 1...100_000) {
                            Text("\(totalUses) total uses")
                        }
                    }
                }
                Section("Redemptions") {
                    LabeledContent("Times redeemed", value: "\(coupon.timesRedeemed)")
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(coupon.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(submitting ? "Saving…" : "Save") { submit() }
                        .disabled(submitting || name.trimmingCharacters(in: .whitespaces).isEmpty || validUntil <= validFrom)
                }
            }
        }
    }

    private func submit() {
        submitting = true
        errorMessage = nil
        Task {
            do {
                _ = try await viewModel.update(
                    endpointURL: endpointURL,
                    operatorNpub: operatorNpub,
                    couponId: coupon.id,
                    name: name == coupon.name ? nil : name.trimmingCharacters(in: .whitespaces),
                    discountPercent: discountPercent == coupon.discountPercent ? nil : discountPercent,
                    validFrom: validFrom == coupon.validFrom ? nil : validFrom,
                    validUntil: validUntil == coupon.validUntil ? nil : validUntil,
                    usesPerPatron: unlimitedPerPatron ? nil : usesPerPatron,
                    totalUses: unlimitedTotal ? nil : totalUses,
                    clearUsesPerPatron: unlimitedPerPatron && coupon.usesPerPatron != nil,
                    clearTotalUses: unlimitedTotal && coupon.totalUses != nil,
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                submitting = false
            }
        }
    }
}
