import SwiftUI
import SwiftData
import WebKit

/// Displays the dpyc-community GitHub page as a canvas for entities
/// that have no economic content (e.g., the Prime Authority / Oracle),
/// with a roll-up of locally-known network membership above it.
struct CommunityCanvasView: View {
    @Query(sort: \Authority.addedAt) private var authorities: [Authority]
    @Query(sort: \Operator.addedAt) private var operators: [Operator]

    private let url = URL(string: "https://github.com/lonniev/dpyc-community")!

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
        HStack(spacing: 28) {
            stat(label: "Authorities", value: nonPrimeAuthorities)
            stat(label: "Operators", value: operators.count)
            stat(label: "Live endpoints", value: operatorsWithEndpoint)
            Spacer()
            Text("locally observed — full network counts via dpyc-oracle")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private func stat(label: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
