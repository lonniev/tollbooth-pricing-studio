import SwiftUI

struct ConnectionStatusView: View {
    let step: String
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            LoadingQuoteView()
                .padding(.bottom, 48)

            // Spinner + step label cluster
            VStack(spacing: 16) {
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
                    .padding(.top, 4)
                }
            }

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
