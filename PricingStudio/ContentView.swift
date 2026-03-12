import SwiftUI

struct ContentView: View {
    private let sidebarItems = ["Tool Prices", "Constraints", "Models"]
    @State private var selectedItem: String?

    var body: some View {
        NavigationSplitView {
            List(sidebarItems, id: \.self, selection: $selectedItem) { item in
                Label(item, systemImage: iconName(for: item))
            }
            .navigationTitle("Pricing Studio")
        } detail: {
            if let selected = selectedItem {
                Text(selected)
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 24) {
                    Image("MiloGreeting")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 600)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(radius: 8)
                    Text("Hello, Pricing Studio")
                        .font(.largeTitle.bold())
                    Text("Select an item from the sidebar to begin.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func iconName(for item: String) -> String {
        switch item {
        case "Tool Prices": return "tag"
        case "Constraints": return "lock.shield"
        case "Models": return "cube.transparent"
        default: return "circle"
        }
    }
}

#Preview {
    ContentView()
}
