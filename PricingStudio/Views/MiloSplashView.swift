import SwiftUI

/// Full-screen Milo greeting shown on cold launch and again after the app has
/// been idle in the background past a threshold. Any tap dismisses it — a soft
/// "sleep screen" that keeps Milo present without gating the app behind it.
struct MiloSplashView: View {
    var onDismiss: () -> Void

    /// True once the user has tapped past Milo at least once. First-ever launch
    /// invites them to "begin"; every idle re-arm after that is a "resume."
    @AppStorage("milo.hasBegun") private var hasBegun = false

    private var prompt: String {
        hasBegun ? "Tap to resume DPYC Commerce" : "Tap to begin"
    }

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

                Text(prompt)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            hasBegun = true
            onDismiss()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Pricing Studio. \(prompt).")
    }
}

#Preview {
    MiloSplashView(onDismiss: {})
}
