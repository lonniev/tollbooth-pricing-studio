import SwiftUI

/// Wraps the existing detail pane with a configurable | Messages segmented control.
struct ChatContainerView<PricingContent: View>: View {
    let identity: ChatIdentity
    @Bindable var chatVM: ChatViewModel
    let firstTabLabel: String
    @ViewBuilder let pricingContent: () -> PricingContent

    @State private var selectedTab: Tab = .pricing

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
    }

    enum Tab: String, CaseIterable {
        case pricing = "Pricing"
        case messages = "Messages"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $selectedTab) {
                Text(firstTabLabel).tag(Tab.pricing)
                Text("Messages").tag(Tab.messages)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch selectedTab {
            case .pricing:
                pricingContent()
            case .messages:
                if identity.hasNsec {
                    ChatView(chatVM: chatVM)
                        .task {
                            chatVM.switchIdentity(to: identity)
                        }
                } else {
                    NoNsecView(entityName: identity.displayName)
                }
            }
        }
    }
}
