import SwiftUI

/// Rotating quotes fetched from the dpyc-community registry,
/// displayed during loading screens with gentle fade transitions.
struct LoadingQuoteView: View {
    @State private var currentIndex: Int = 0
    @State private var opacity: Double = 0.0
    @State private var quotes: [Quote] = []

    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    private var displayQuotes: [Quote] {
        quotes.isEmpty ? Self.inlineDefaults : quotes
    }

    private static let inlineDefaults: [Quote] = [
        Quote(text: "Sound money is an instrument of protection of civil liberties against despotic inroads on the part of governments.", author: "Ludwig von Mises"),
        Quote(text: "The curious task of economics is to demonstrate to men how little they really know about what they imagine they can design.", author: "F.A. Hayek"),
        Quote(text: "The root problem with conventional currency is all the trust that's required to make it work.", author: "Satoshi Nakamoto"),
    ]

    var body: some View {
        let active = displayQuotes
        let quote = active[currentIndex % active.count]

        VStack(spacing: 12) {
            Text("\u{201C}\(quote.text)\u{201D}")
                .font(.body)
                .italic()
                .foregroundStyle(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            Text(quote.author)
                .font(.caption)
                .fontWeight(.medium)
                .tracking(1.5)
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
        }
        .opacity(opacity)
        .onReceive(timer) { _ in
            advance()
        }
        .padding(.horizontal, 32)
        .onAppear {
            currentIndex = Int.random(in: 0..<active.count)
            withAnimation(.easeIn(duration: 0.5)) {
                opacity = 1.0
            }
        }
        .task {
            let remote = await QuoteStore.shared.shuffled()
            if !remote.isEmpty {
                quotes = remote
                currentIndex = 0
            }
        }
    }

    private func advance() {
        let active = displayQuotes
        guard active.count > 1 else { return }
        withAnimation(.easeOut(duration: 0.4)) {
            opacity = 0.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            var next = Int.random(in: 0..<active.count)
            if active.count > 1 { while next == currentIndex { next = Int.random(in: 0..<active.count) } }
            currentIndex = next
            withAnimation(.easeIn(duration: 0.5)) {
                opacity = 1.0
            }
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
        .frame(width: 500, height: 300)
}
