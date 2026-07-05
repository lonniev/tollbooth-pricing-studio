import SwiftUI
import SwiftData
import WebKit

/// Displays the dpyc-community GitHub page as a canvas for entities
/// that have no economic content (e.g., the Prime Authority / Oracle),
/// with a roll-up of locally-known network membership above it.
struct CommunityCanvasView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Query(sort: \Authority.addedAt) private var authorities: [Authority]
    @Query(sort: \Operator.addedAt) private var operators: [Operator]

    private let url = URL(string: "https://github.com/lonniev/dpyc-community")!
    private var isCompact: Bool { sizeClass == .compact }

    var body: some View {
        VStack(spacing: 0) {
            statsBanner
            Divider()
            WebViewWrapper(url: url)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private var nonPrimeAuthorities: Int {
        authorities.filter { !$0.isPrime }.count
    }

    private var operatorsWithEndpoint: Int {
        operators.filter { ($0.mcpEndpointURL ?? "").isEmpty == false }.count
    }

    private var statsBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Three across is fine on the wide iPad column; on a phone the
            // cards read better stacked full-width.
            let layout = isCompact
                ? AnyLayout(VStackLayout(spacing: 8))
                : AnyLayout(HStackLayout(spacing: 12))
            layout {
                statCard(
                    label: "Authorities",
                    value: nonPrimeAuthorities,
                    icon: "building.columns.fill",
                    tint: .indigo
                )
                statCard(
                    label: "Operators",
                    value: operators.count,
                    icon: "server.rack",
                    tint: .teal
                )
                statCard(
                    label: "Live endpoints",
                    value: operatorsWithEndpoint,
                    icon: "antenna.radiowaves.left.and.right",
                    tint: .green
                )
            }
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.caption2)
                Text("Locally observed — full network counts via dpyc-oracle")
                    .font(.caption2)
            }
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private func statCard(label: String, value: Int, icon: String, tint: Color) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("\(value)")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Text(label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.background.secondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(0.25), lineWidth: 0.5)
        )
    }
}

private struct WebViewWrapper: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
