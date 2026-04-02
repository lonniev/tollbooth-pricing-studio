import SwiftUI

/// Tab cases shared across all ChatContainerView specializations.
enum ChatContainerTab: String, CaseIterable {
    case authority = "Authority"
    case pricing = "Pricing"
    case invoices = "Invoices"
    case consultant = "Campaign Advisor"
    case messages = "Messages"
}

/// Wraps the existing detail pane with a configurable | Messages segmented control.
/// Optionally shows an "Invoices" tab and/or a "Consultant" tab when the corresponding views are provided.
struct ChatContainerView<PricingContent: View, InvoicesContent: View, ConsultantContent: View>: View {
    let identity: ChatIdentity
    @Bindable var chatVM: ChatViewModel
    let firstTabLabel: String
    @ViewBuilder let pricingContent: () -> PricingContent
    let invoicesContent: (() -> InvoicesContent)?
    let consultantContent: (() -> ConsultantContent)?

    @Binding var selectedTab: ChatContainerTab

    init(
        identity: ChatIdentity,
        chatVM: ChatViewModel,
        selectedTab: Binding<ChatContainerTab>,
        firstTabLabel: String = "Pricing",
        @ViewBuilder pricingContent: @escaping () -> PricingContent,
        invoicesContent: (() -> InvoicesContent)? = nil,
        consultantContent: (() -> ConsultantContent)? = nil
    ) {
        self.identity = identity
        self.chatVM = chatVM
        self._selectedTab = selectedTab
        self.firstTabLabel = firstTabLabel
        self.pricingContent = pricingContent
        self.invoicesContent = invoicesContent
        self.consultantContent = consultantContent
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $selectedTab) {
                Text(firstTabLabel).tag(ChatContainerTab.pricing)
                if invoicesContent != nil {
                    Text("Invoices").tag(ChatContainerTab.invoices)
                }
                if consultantContent != nil {
                    Text("Campaign Advisor").tag(ChatContainerTab.consultant)
                }
                Text("Messages").tag(ChatContainerTab.messages)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .accessibilityIdentifier("detailTabPicker")
            .onAppear {
                // Reset to first tab if current selection isn't available in this view
                if selectedTab == .authority || selectedTab == .consultant && consultantContent == nil
                    || selectedTab == .invoices && invoicesContent == nil {
                    selectedTab = .pricing
                }
            }

            switch selectedTab {
            case .authority:
                // Only meaningful on the operator detail (handled by ContentView).
                // If we land here, fall through to pricing.
                pricingContent()
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
        selectedTab: Binding<ChatContainerTab>,
        firstTabLabel: String = "Pricing",
        @ViewBuilder pricingContent: @escaping () -> PricingContent
    ) {
        self.identity = identity
        self.chatVM = chatVM
        self._selectedTab = selectedTab
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
        selectedTab: Binding<ChatContainerTab>,
        firstTabLabel: String = "Pricing",
        @ViewBuilder pricingContent: @escaping () -> PricingContent,
        @ViewBuilder invoicesContent: @escaping () -> InvoicesContent
    ) {
        self.identity = identity
        self.chatVM = chatVM
        self._selectedTab = selectedTab
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
        selectedTab: Binding<ChatContainerTab>,
        firstTabLabel: String = "Pricing",
        @ViewBuilder pricingContent: @escaping () -> PricingContent,
        consultantContent: @escaping () -> ConsultantContent
    ) {
        self.identity = identity
        self.chatVM = chatVM
        self._selectedTab = selectedTab
        self.firstTabLabel = firstTabLabel
        self.pricingContent = pricingContent
        self.invoicesContent = nil
        self.consultantContent = consultantContent
    }
}
