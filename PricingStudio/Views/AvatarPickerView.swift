import SwiftUI
import SVGView

// MARK: - Shared catalog (keep in sync with eXcalibur FE's Avatar.tsx / AvatarPicker.tsx)

/// The avatar source-of-truth shared with eXcalibur's React picker so both
/// apps offer the SAME choices: the Iconify SVG catalog plus a fixed glyph set.
enum AvatarCatalog {
    /// Identical to `AVATAR_CHOICES` in eXcalibur's Avatar.tsx.
    static let glyphs: [String] = [
        "🐂", "🐻", "🦂", "🦅", "🐺", "🦉",
        "🦊", "🐉", "🦄", "🐢", "🦈", "🦀",
        "🎩", "🎭", "🃏", "🎯", "🪙", "💎",
        "⚡", "🔥", "🌪️", "🌊", "🏔️", "🌋",
        "♟️", "♛", "🛡️", "⚔️", "🗝️", "📜",
    ]

    /// Identical collection set to eXcalibur's AvatarPicker.tsx.
    static let collections: [(prefix: String, label: String)] = [
        ("fluent-emoji-flat", "Fluent — Microsoft, flat"),
        ("twemoji", "Twemoji — Twitter's set"),
        ("noto", "Noto — Google"),
        ("openmoji", "OpenMoji — CC-BY-SA"),
        ("emojione-v1", "EmojiOne — classic"),
    ]

    static let pageSize = 30

    static func iconURL(prefix: String, name: String) -> URL? {
        URL(string: "https://api.iconify.design/\(prefix)/\(name).svg")
    }

    static func isURL(_ v: String) -> Bool {
        let s = v.lowercased()
        return s.hasPrefix("http://") || s.hasPrefix("https://") || s.hasPrefix("data:image/")
    }

    static func isSVG(_ v: String) -> Bool {
        isURL(v) && (v.lowercased().contains(".svg") || v.lowercased().hasPrefix("data:image/svg"))
    }
}

// MARK: - Remote SVG loading (cached) — renders an Iconify SVG via SVGView

@MainActor
final class SVGDataCache {
    static let shared = SVGDataCache()
    private var cache: [String: Data] = [:]

    func data(for url: URL) async -> Data? {
        let key = url.absoluteString
        if let hit = cache[key] { return hit }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            cache[key] = data
            return data
        } catch {
            return nil
        }
    }
}

/// Async-loads an SVG by URL and renders it with SVGView; shows a spinner while
/// loading and a neutral glyph if the fetch fails.
struct RemoteSVG: View {
    let url: URL
    var size: CGFloat = 40
    @State private var data: Data?
    @State private var failed = false

    var body: some View {
        Group {
            if let data {
                SVGView(data: data)
                    .frame(width: size, height: size)
            } else if failed {
                Text("🖼️").font(.system(size: size * 0.6))
            } else {
                ProgressView().controlSize(.small)
                    .frame(width: size, height: size)
            }
        }
        .task(id: url) {
            let loaded = await SVGDataCache.shared.data(for: url)
            if let loaded { data = loaded } else { failed = true }
        }
    }
}

// MARK: - Avatar renderer (emoji / raster URL / SVG URL) — mirrors React Avatar.tsx

/// Renders an avatar value: an emoji glyph, a raster image URL, or an SVG URL.
struct AvatarView: View {
    let value: String
    var size: CGFloat = 40

    var body: some View {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        Group {
            if AvatarCatalog.isURL(raw), let url = URL(string: raw) {
                if AvatarCatalog.isSVG(raw) {
                    RemoteSVG(url: url, size: size)
                } else {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        ProgressView().controlSize(.small)
                    }
                }
            } else {
                Text(raw.isEmpty ? "🃏" : raw)
                    .font(.system(size: size * 0.58))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.gray.opacity(0.3)))
    }
}

// MARK: - Patron avatar (Nostr picture when set, else the generic glyph)

/// Renders a patron's cached Nostr avatar (``pictureURL``) when one is set, so
/// patrons are visually distinguishable wherever they appear; otherwise falls
/// back to the generic ``person.badge.key`` glyph used elsewhere in Studio.
struct PatronAvatar: View {
    let pictureURL: String?
    var size: CGFloat = 40

    var body: some View {
        if let url = pictureURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !url.isEmpty {
            AvatarView(value: url, size: size)
        } else {
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: size * 0.6))
                .foregroundStyle(.teal)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Icon catalog fetch (Iconify collection name lists, cached)

private struct IconifyCollection: Decodable {
    let uncategorized: [String]?
    let categories: [String: [String]]?
}

@MainActor
final class IconCatalogModel: ObservableObject {
    @Published var names: [String] = []
    @Published var loading = false
    @Published var error: String?
    private var cache: [String: [String]] = [:]

    func load(prefix: String) async {
        if let cached = cache[prefix] {
            names = cached; error = nil; loading = false; return
        }
        loading = true; error = nil; names = []
        guard let url = URL(string: "https://api.iconify.design/collection?prefix=\(prefix)") else {
            loading = false; return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(IconifyCollection.self, from: data)
            var out: [String] = []
            if let cats = decoded.categories { for (_, v) in cats { out.append(contentsOf: v) } }
            if let unc = decoded.uncategorized { out.append(contentsOf: unc) }
            cache[prefix] = out
            names = out
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

// MARK: - The picker

struct AvatarPickerView: View {
    @Binding var selectedURL: String

    private enum Tab: String, CaseIterable { case catalog = "Catalog", glyphs = "Glyphs" }

    @State private var tab: Tab = .catalog
    @State private var collection = AvatarCatalog.collections[0].prefix
    @State private var page = 0
    @State private var showCustom = false
    @State private var customURL = ""
    @StateObject private var catalog = IconCatalogModel()

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            tabBar
            if tab == .catalog { catalogTab } else { glyphsTab }
            customSection
            if !selectedURL.isEmpty { preview }
        }
    }

    // MARK: Tabs

    private var tabBar: some View {
        Picker("", selection: $tab) {
            ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    // MARK: Catalog

    private var totalPages: Int { max(1, Int(ceil(Double(catalog.names.count) / Double(AvatarCatalog.pageSize)))) }

    private var visibleNames: [String] {
        let start = page * AvatarCatalog.pageSize
        guard start < catalog.names.count else { return [] }
        return Array(catalog.names[start ..< min(start + AvatarCatalog.pageSize, catalog.names.count)])
    }

    private var catalogTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Collection", selection: $collection) {
                ForEach(AvatarCatalog.collections, id: \.prefix) { Text($0.label).tag($0.prefix) }
            }
            .pickerStyle(.menu)

            if catalog.loading {
                HStack { ProgressView().controlSize(.small); Text("Loading…").foregroundStyle(.secondary).font(.caption) }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else if let error = catalog.error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(visibleNames, id: \.self) { name in
                        if let url = AvatarCatalog.iconURL(prefix: collection, name: name) {
                            tile(isSelected: selectedURL == url.absoluteString) {
                                RemoteSVG(url: url, size: 32)
                            } action: {
                                selectedURL = url.absoluteString
                            }
                        }
                    }
                }
                if totalPages > 1 { pager }
            }
        }
        .onChange(of: collection) { _, _ in page = 0 }
        .task(id: collection) { await catalog.load(prefix: collection) }
    }

    private var pager: some View {
        HStack {
            Button { if page > 0 { page -= 1 } } label: { Image(systemName: "chevron.left") }
                .disabled(page == 0)
            Spacer()
            Text("\(page + 1) / \(totalPages)").font(.caption.monospaced()).foregroundStyle(.secondary)
            Spacer()
            Button { if page < totalPages - 1 { page += 1 } } label: { Image(systemName: "chevron.right") }
                .disabled(page >= totalPages - 1)
        }
        .buttonStyle(.bordered)
        .padding(.top, 4)
    }

    // MARK: Glyphs

    private var glyphsTab: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(AvatarCatalog.glyphs, id: \.self) { glyph in
                tile(isSelected: selectedURL == glyph) {
                    Text(glyph).font(.system(size: 26))
                } action: {
                    selectedURL = glyph
                }
            }
        }
    }

    // MARK: Custom URL

    private var customSection: some View {
        DisclosureGroup("Custom image URL", isExpanded: $showCustom) {
            TextField("https://… or a single emoji", text: $customURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .padding(8)
                .background(Color(UIColor.systemGray6))
                .cornerRadius(6)
                .onChange(of: customURL) { _, newValue in selectedURL = newValue }
        }
        .font(.subheadline)
    }

    // MARK: Preview

    private var preview: some View {
        HStack(spacing: 12) {
            AvatarView(value: selectedURL, size: 48)
            Text("Selected").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 4)
    }

    // MARK: Tile

    /// A selectable tile with a persistent selection ring — `.plain` style so it
    /// doesn't flash the system tap highlight over the selection state.
    private func tile<Content: View>(
        isSelected: Bool, @ViewBuilder content: () -> Content, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            content()
                .frame(height: 40)
                .frame(maxWidth: .infinity)
                .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.25),
                                lineWidth: isSelected ? 2 : 1)
                )
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.accentColor)
                            .padding(2)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}
