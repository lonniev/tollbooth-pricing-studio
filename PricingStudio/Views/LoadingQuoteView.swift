import SwiftUI

/// Rotating quotes fetched from the dpyc-community registry,
/// displayed during loading screens.
struct LoadingQuoteView: View {
    @State private var currentIndex: Int = 0
    @State private var opacity: Double = 1.0
    @State private var quotes: [Quote] = []

    private let timer = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if quotes.isEmpty {
                EmptyView()
            } else {
                let quote = quotes[currentIndex]
                VStack(spacing: 8) {
                    Text("\u{201C}\(quote.text)\u{201D}")
                        .font(.callout)
                        .italic()
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                        .lineSpacing(3)

                    Text("— \(quote.author)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .opacity(opacity)
                .animation(.easeInOut(duration: 0.8), value: opacity)
                .onReceive(timer) { _ in
                    advance()
                }
                .padding(.horizontal, 24)
            }
        }
        .task {
            quotes = await QuoteStore.shared.shuffled()
            if !quotes.isEmpty {
                currentIndex = 0
            }
        }
    }

    private func advance() {
        guard quotes.count > 1 else { return }
        opacity = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            currentIndex = (currentIndex + 1) % quotes.count
            opacity = 1
        }
    }
}

// MARK: - Quote model

private struct Quote: Codable, Sendable {
    let text: String
    let author: String
}

// MARK: - QuoteStore — fetch once, cache, shuffle per consumer

private actor QuoteStore {
    static let shared = QuoteStore()

    private var cached: [Quote]?
    private var fetchTask: Task<[Quote], Never>?

    private static let remoteURL = URL(
        string: "https://raw.githubusercontent.com/lonniev/dpyc-community/main/quotes.json"
    )!

    private static let fallback: [Quote] = [
        Quote(text: "Sound money is an instrument of protection of civil liberties against despotic inroads on the part of governments.", author: "Ludwig von Mises"),
        Quote(text: "The curious task of economics is to demonstrate to men how little they really know about what they imagine they can design.", author: "F.A. Hayek"),
        Quote(text: "The root problem with conventional currency is all the trust that's required to make it work.", author: "Satoshi Nakamoto"),
        Quote(text: "I don't believe we shall ever have a good money again before we take the thing out of the hands of government.", author: "F.A. Hayek"),
        Quote(text: "Inflation is taxation without legislation.", author: "Milton Friedman"),
    ]

    /// Prefetch quotes in the background. Call early (e.g. at app launch).
    func prefetch() {
        guard fetchTask == nil else { return }
        fetchTask = Task {
            await load()
        }
    }

    /// Return a shuffled copy of the quote corpus.
    func shuffled() async -> [Quote] {
        let all = await load()
        return all.shuffled()
    }

    private func load() async -> [Quote] {
        if let cached { return cached }

        // Wait for in-flight fetch if one exists
        if let fetchTask {
            return await fetchTask.value
        }

        let quotes = await fetchRemote()
        cached = quotes
        return quotes
    }

    private func fetchRemote() async -> [Quote] {
        do {
            let (data, response) = try await URLSession.shared.data(from: Self.remoteURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return Self.fallback
            }
            let payload = try JSONDecoder().decode(QuotePayload.self, from: data)
            guard !payload.quotes.isEmpty else { return Self.fallback }
            return payload.quotes
        } catch {
            return Self.fallback
        }
    }

    private struct QuotePayload: Codable {
        let quotes: [Quote]
    }
}

// MARK: - App-level prefetch hook

extension LoadingQuoteView {
    /// Call once at app startup to begin fetching quotes in the background.
    static func prefetch() {
        Task { await QuoteStore.shared.prefetch() }
    }
}

#Preview {
    LoadingQuoteView()
        .frame(width: 500, height: 200)
}
