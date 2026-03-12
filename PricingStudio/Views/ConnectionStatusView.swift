import SwiftUI

struct ConnectionStatusView: View {
    let step: String

    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)

            Text(step)
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .animation(.easeInOut, value: step)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
