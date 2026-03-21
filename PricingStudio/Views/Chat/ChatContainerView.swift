import SwiftUI

/// Wraps the existing detail pane with a configurable | Messages segmented control.
/// Optionally shows a third "Consultant" tab when a consultant view is provided.
struct ChatContainerView<PricingContent: View, ConsultantContent: View>: View {
    let identity: ChatIdentity
    @Bindable var chatVM: ChatViewModel
    let firstTabLabel: String
    @ViewBuilder let pricingContent: () -> PricingContent
    let consultantContent: (() -> ConsultantContent)?

    @State private var selectedTab: Tab = .pricing

    init(
        identity: ChatIdentity,
        chatVM: ChatViewModel,
        firstTabLabel: String = "Pricing",
        @ViewBuilder pricingContent: @escaping () -> PricingContent,
        consultantContent: (() -> ConsultantContent)? = nil
    ) {
        self.identity = identity
        self.chatVM = chatVM
        self.firstTabLabel = firstTabLabel
        self.pricingContent = pricingContent
        self.consultantContent = consultantContent
    }

    enum Tab: String, CaseIterable {
        case pricing = "Pricing"
        case consultant = "Campaign Advisor"
        case messages = "Messages"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $selectedTab) {
                Text(firstTabLabel).tag(Tab.pricing)
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

// Convenience init without consultant tab
extension ChatContainerView where ConsultantContent == EmptyView {
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
        self.consultantContent = nil
    }
}
