import SwiftUI

/// Wraps the existing detail pane with a configurable | Messages segmented control.
/// Optionally shows an "Invoices" tab and/or a "Consultant" tab when the corresponding views are provided.
struct ChatContainerView<PricingContent: View, InvoicesContent: View, ConsultantContent: View>: View {
    let identity: ChatIdentity
    @Bindable var chatVM: ChatViewModel
    let firstTabLabel: String
    @ViewBuilder let pricingContent: () -> PricingContent
    let invoicesContent: (() -> InvoicesContent)?
    let consultantContent: (() -> ConsultantContent)?

    @State private var selectedTab: Tab = .pricing

    init(
        identity: ChatIdentity,
        chatVM: ChatViewModel,
        firstTabLabel: String = "Pricing",
        @ViewBuilder pricingContent: @escaping () -> PricingContent,
        invoicesContent: (() -> InvoicesContent)? = nil,
        consultantContent: (() -> ConsultantContent)? = nil
    ) {
        self.identity = identity
        self.chatVM = chatVM
        self.firstTabLabel = firstTabLabel
        self.pricingContent = pricingContent
        self.invoicesContent = invoicesContent
        self.consultantContent = consultantContent
    }

    enum Tab: String, CaseIterable {
        case pricing = "Pricing"
        case invoices = "Invoices"
        case consultant = "Campaign Advisor"
        case messages = "Messages"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $selectedTab) {
                Text(firstTabLabel).tag(Tab.pricing)
                if invoicesContent != nil {
                    Text("Invoices").tag(Tab.invoices)
                }
                if consultantContent != nil {
                    Text("Campaign Advisor").tag(Tab.consultant)
                }
                Text("Messages").tag(Tab.messages)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .accessibilityIdentifier("detailTabPicker")

            switch selectedTab {
            case .pricing:
                pricingContent()
            case .invoices:
                if let invoicesContent {
                    invoicesContent()
                }
            case .messages:
                if identity.hasNsec {
                    ChatView(chatVM: chatVM)
                        .onAppear {
                            chatVM.switchIdentity(to: identity)
                        }
                } else {
                    NoNsecView(entityName: identity.displayName)
                }
            case .consultant:
                if let consultantContent {
                    consultantContent()
                }
            }
        }
    }
}

// Convenience init without consultant or invoices tabs
extension ChatContainerView where ConsultantContent == EmptyView, InvoicesContent == EmptyView {
    init(
        identity: ChatIdentity,
        chatVM: ChatViewModel,
        firstTabLabel: String = "Pricing",
        @ViewBuilder pricingContent: @escaping () -> PricingContent
    ) {
        self.identity = identity
        self.chatVM = chatVM
        self.firstTabLabel = firstTabLabel
        self.pricingContent = pricingContent
        self.invoicesContent = nil
        self.consultantContent = nil
    }
}

// Convenience init with invoices but no consultant
extension ChatContainerView where ConsultantContent == EmptyView {
    init(
        identity: ChatIdentity,
        chatVM: ChatViewModel,
        firstTabLabel: String = "Pricing",
        @ViewBuilder pricingContent: @escaping () -> PricingContent,
        @ViewBuilder invoicesContent: @escaping () -> InvoicesContent
    ) {
        self.identity = identity
        self.chatVM = chatVM
        self.firstTabLabel = firstTabLabel
        self.pricingContent = pricingContent
        self.invoicesContent = invoicesContent
        self.consultantContent = nil
    }
}

// Convenience init with consultant but no invoices
extension ChatContainerView where InvoicesContent == EmptyView {
    init(
        identity: ChatIdentity,
        chatVM: ChatViewModel,
        firstTabLabel: String = "Pricing",
        @ViewBuilder pricingContent: @escaping () -> PricingContent,
        consultantContent: @escaping () -> ConsultantContent
    ) {
        self.identity = identity
        self.chatVM = chatVM
        self.firstTabLabel = firstTabLabel
        self.pricingContent = pricingContent
        self.invoicesContent = nil
        self.consultantContent = consultantContent
    }
}
