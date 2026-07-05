import SwiftUI

/// Full-screen Milo greeting shown on cold launch and again after the app has
/// been idle in the background past a threshold. Any tap dismisses it — a soft
/// "sleep screen" that keeps Milo present without gating the app behind it.
struct MiloSplashView: View {
    var onDismiss: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.background)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Image("MiloGreeting")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .shadow(radius: 12)

                Text("Pricing Studio")
                    .font(.largeTitle.bold())

                Text("Tap to begin")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Pricing Studio. Tap to begin.")
    }
}

#Preview {
    MiloSplashView(onDismiss: {})
}
