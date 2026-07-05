import SwiftUI

/// One detail tab: the routing value plus its display label. The label is
/// computed by the caller (e.g. the Messages tab swaps its glyph on unread),
/// so this stays a plain data record shared across formats.
struct DetailTab: Equatable, Identifiable {
    let tab: ChatContainerTab
    let label: String
    var id: ChatContainerTab { tab }
}

/// Format-appropriate tab selector for the actor-detail pane.
///
/// The three actor details (Authority/Operator/Patron) each expose 3–6 tabs.
/// A `.segmented` Picker is right on the wide iPad detail column but overflows
/// and clips on a portrait phone. Same tab data, two renderings:
///   • regular width → the familiar segmented control
///   • compact width → a horizontally scrollable strip of pills, so every tab
///     stays reachable and legible, auto-scrolling the selection into view
///
/// It also snaps the selection to the first available tab whenever the current
/// one isn't in the list (an actor switch can leave `detailTab` on a tab the
/// new actor doesn't have), so the detail pane never renders blank.
struct AdaptiveTabBar: View {
    let tabs: [DetailTab]
    @Binding var selection: ChatContainerTab
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sizeClass == .compact {
                compactStrip
            } else {
                segmented
            }
        }
        .onAppear(perform: snapIfNeeded)
        .onChange(of: tabs) { _, _ in snapIfNeeded() }
    }

    private var segmented: some View {
        Picker("View", selection: $selection) {
            ForEach(tabs) { t in
                Text(t.label).tag(t.tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
    }

    private var compactStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tabs) { t in
                        let isSelected = t.tab == selection
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { selection = t.tab }
                        } label: {
                            Text(t.label)
                                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                                .lineLimit(1)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule().fill(
                                        isSelected
                                            ? Color.accentColor.opacity(0.18)
                                            : Color(.secondarySystemFill)
                                    )
                                )
                                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .id(t.tab)
                    }
                }
                .padding(.horizontal)
            }
            .onChange(of: selection) { _, new in
                withAnimation { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    /// Keep `selection` valid for the current tab set.
    private func snapIfNeeded() {
        guard !tabs.isEmpty, !tabs.contains(where: { $0.tab == selection }) else { return }
        if let first = tabs.first?.tab { selection = first }
    }
}
