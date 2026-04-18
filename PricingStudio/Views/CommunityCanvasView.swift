import SwiftUI
import WebKit

/// Displays the dpyc-community GitHub page as a canvas for entities
/// that have no economic content (e.g., the Prime Authority / Oracle).
struct CommunityCanvasView: View {
    private let url = URL(string: "https://github.com/lonniev/dpyc-community")!

    var body: some View {
        WebViewWrapper(url: url)
            .ignoresSafeArea(edges: .bottom)
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
