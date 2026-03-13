import SwiftUI

/// Wraps the existing detail pane with a Pricing | Messages segmented control.
struct ChatContainerView<PricingContent: View>: View {
    let identity: ChatIdentity
    @Bindable var chatVM: ChatViewModel
    @ViewBuilder let pricingContent: () -> PricingContent

    @State private var selectedTab: Tab = .pricing

    enum Tab: String, CaseIterable {
        case pricing = "Pricing"
        case messages = "Messages"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
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
