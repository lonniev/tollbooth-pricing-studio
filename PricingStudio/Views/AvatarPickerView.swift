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

// MARK: - Iconify, a page of icons in one request

/// Iconify's JSON API, which returns many icons of one collection in a single request.
/// Fetching each icon's own `.svg` sent thirty requests a page, and paging through the
/// catalog tripped Iconify's rate limit (HTTP 429), so tiles got no icon at all.
enum Iconify {
    /// `prefix` and `name` from an icon URL as ``AvatarCatalog/iconURL(prefix:name:)`` makes it, or nil.
    static func icon(of url: URL) -> (prefix: String, name: String)? {
        guard url.host == "api.iconify.design", url.pathExtension == "svg" else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), url.deletingPathExtension().lastPathComponent)
    }

    /// One request for every icon in `names`.
    static func batchURL(prefix: String, names: [String]) -> URL? {
        var c = URLComponents(string: "https://api.iconify.design/\(prefix).json")
        c?.queryItems = [URLQueryItem(name: "icons", value: names.joined(separator: ","))]
        return c?.url
    }

    private struct Batch: Decodable {
        struct Icon: Decodable { let body: String; let width, height, left, top: Double? }
        struct Alias: Decodable { let parent: String }
        let icons: [String: Icon]?
        let aliases: [String: Alias]?
        let width, height, left, top: Double?
    }

    /// Each named icon in a batch response as a standalone SVG document; names it lacks are left out.
    static func documents(from data: Data) -> [String: Data] {
        guard let batch = try? JSONDecoder().decode(Batch.self, from: data) else { return [:] }
        let icons = batch.icons ?? [:]
        var out: [String: Data] = [:]
        func svg(_ icon: Batch.Icon) -> Data {
            let w = icon.width ?? batch.width ?? 16, h = icon.height ?? batch.height ?? 16
            let x = icon.left ?? batch.left ?? 0, y = icon.top ?? batch.top ?? 0
            let doc = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(fmt(w))\" height=\"\(fmt(h))\" "
                + "viewBox=\"\(fmt(x)) \(fmt(y)) \(fmt(w)) \(fmt(h))\">\(icon.body)</svg>"
            return Data(doc.utf8)
        }
        for (name, icon) in icons { out[name] = svg(icon) }
        for (name, alias) in batch.aliases ?? [:] { if let parent = icons[alias.parent] { out[name] = svg(parent) } }
        return out
    }

    private static func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }

    /// Whether a fetched body is an SVG document, and not an error page served in its place.
    static func isSVG(_ data: Data) -> Bool {
        guard let head = String(data: data.prefix(512), encoding: .utf8)?.lowercased() else { return false }
        return head.contains("<svg")
    }
}

// MARK: - Remote SVG loading (cached) — renders an Iconify SVG via SVGView

@MainActor
final class SVGDataCache {
    static let shared = SVGDataCache()
    private var cache: [String: Data] = [:]

    /// An icon's SVG: from the cache, from Iconify's JSON API for an Iconify icon, else by URL.
    /// Only a 200 that really is an SVG is kept; a refusal is not cached, so it is asked again later.
    func data(for url: URL) async -> Data? {
        let key = url.absoluteString
        if let hit = cache[key] { return hit }
        if let icon = Iconify.icon(of: url) {
            await prefetch(prefix: icon.prefix, names: [icon.name])
            return cache[key]
        }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, Iconify.isSVG(data) else { return nil }
        cache[key] = data
        return data
    }

    /// Fetch every icon in `names` that is not cached yet, in one request.
    func prefetch(prefix: String, names: [String]) async {
        let wanted = names.filter { name in
            AvatarCatalog.iconURL(prefix: prefix, name: name).map { cache[$0.absoluteString] == nil } ?? false
        }
        guard !wanted.isEmpty, let url = Iconify.batchURL(prefix: prefix, names: wanted),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        for (name, svg) in Iconify.documents(from: data) {
            if let key = AvatarCatalog.iconURL(prefix: prefix, name: name)?.absoluteString { cache[key] = svg }
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
        // Always a sized box: an SVG that draws nothing must not collapse its tile and row.
        Color.clear
            .frame(width: size, height: size)
            .overlay {
                if let data {
                    SVGView(data: data).frame(width: size, height: size)
                } else if failed {
                    Text("🖼️").font(.system(size: size * 0.6))
                } else {
                    ProgressView().controlSize(.small)
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
    /// The page whose icons are fetched, one request a page; tiles wait for it.
    @State private var pageReady = ""
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
                                if pageReady == "\(collection)/\(page)" {
                                    RemoteSVG(url: url, size: 32)
                                } else {
                                    ProgressView().controlSize(.small).frame(width: 32, height: 32)
                                }
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
        .task(id: "\(collection)/\(page)/\(catalog.names.count)") {
            await SVGDataCache.shared.prefetch(prefix: collection, names: visibleNames)
            pageReady = "\(collection)/\(page)"
        }
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
