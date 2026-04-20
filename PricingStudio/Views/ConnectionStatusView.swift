import SwiftUI

struct ConnectionStatusView: View {
    let step: String
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)

            Text(step)
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .animation(.easeInOut, value: step)

            if let onCancel {
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .padding(.top, 8)
            }

            Spacer()
                .frame(height: 24)

            LoadingQuoteView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
