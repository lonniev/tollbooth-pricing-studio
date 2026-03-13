import SwiftUI

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 24) {
            Image("MiloGreeting")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 500)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 8)

            Text("Pricing Studio")
                .font(.largeTitle.bold())

            Text("Select an operator from the sidebar to view their pricing model.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    EmptyStateView()
}
