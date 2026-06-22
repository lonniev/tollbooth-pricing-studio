import SwiftUI
import UIKit

struct AvatarPickerView: View {
    @Binding var selectedURL: String
    @State private var customURL = ""
    @State private var showCustomInput = false

    private let emojiChoices = [
        "🎨", "🎭", "🎪", "🎬", "🎯", "🎲", "🎸", "🎹", "🎺", "🎻",
        "🏆", "🏅", "🥇", "🥈", "🥉", "⭐", "✨", "💫", "🌟", "🌠",
        "🚀", "🛸", "🛰️", "🌌", "🌃", "🌆", "🌇", "🌉", "🌁", "🌅",
        "🎓", "📚", "📖", "📝", "✏️", "🖊️", "🖍️", "📐", "📏", "📌",
        "💼", "💰", "💳", "💎", "💍", "👑", "🔑", "🔐", "🔓", "🗝️",
        "🧠", "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "🤎",
        "👨‍💼", "👩‍💼", "👨‍💻", "👩‍💻", "🧑‍🎨", "👨‍🎓", "👩‍🎓", "👨‍🔬", "👩‍🔬", "🧑‍🚀",
        "🌟", "💡", "🔥", "⚡", "❄️", "💧", "🌊", "🌪️", "🌈", "☀️",
        "🦁", "🦊", "🐻", "🐼", "🐨", "🐯", "🦅", "🦆", "🐉", "🦄",
        "🌹", "🌺", "🌻", "🌼", "🌷", "🌸", "🌱", "🌿", "🍀", "🌾",
    ]

    var body: some View {
        VStack(spacing: 12) {
            // Emoji grid
            VStack(alignment: .leading, spacing: 8) {
                Text("Emoji Avatar")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 10)
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(emojiChoices, id: \.self) { emoji in
                        Button {
                            selectedURL = emoji
                            showCustomInput = false
                        } label: {
                            Text(emoji)
                                .font(.system(size: 24))
                                .frame(height: 40)
                                .frame(maxWidth: .infinity)
                                .background(selectedURL == emoji ? Color.accentColor.opacity(0.2) : Color.clear)
                                .border(selectedURL == emoji ? Color.accentColor : Color.gray.opacity(0.3), width: 2)
                                .cornerRadius(6)
                        }
                    }
                }
            }

            Divider()

            // Custom URL section
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    showCustomInput.toggle()
                } label: {
                    HStack {
                        Text("Custom Image URL")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(showCustomInput ? 90 : 0))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                if showCustomInput {
                    VStack(spacing: 8) {
                        TextField("https://example.com/avatar.svg", text: $customURL)
                            .autocorrectionDisabled(true)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .padding(8)
                            .background(Color(UIColor.systemGray6))
                            .cornerRadius(6)
                            .onChange(of: customURL) { _, newValue in
                                selectedURL = newValue
                            }

                        Text("PNG, SVG, or JPEG URLs work. Animated GIFs are supported.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Preview
            if !selectedURL.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Preview")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)

                    HStack {
                        if selectedURL.count == 1 || selectedURL.allSatisfy({ $0.unicodeScalars.allSatisfy({ $0.properties.isEmoji }) }) {
                            // Emoji
                            Text(selectedURL)
                                .font(.system(size: 48))
                        } else {
                            // URL image
                            AsyncImage(url: URL(string: selectedURL)) { image in
                                image.resizable().scaledToFit()
                            } placeholder: {
                                Color.gray.opacity(0.2)
                            }
                            .frame(width: 80, height: 80)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.gray.opacity(0.3)))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Selected")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                            Text(String(selectedURL.prefix(40)) + (selectedURL.count > 40 ? "…" : ""))
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .lineLimit(2)
                        }
                        .padding(.leading, 12)

                        Spacer()
                    }
                    .padding(8)
                    .background(Color(UIColor.systemGray6))
                    .cornerRadius(6)
                }
            }
        }
    }
}

#Preview {
    @Previewable @State var url = ""
    AvatarPickerView(selectedURL: $url)
        .padding()
}
