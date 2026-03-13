import SwiftUI

/// Popover for customizing message font name and size.
struct ChatFontPicker: View {
    @Binding var fontName: String
    @Binding var fontSize: CGFloat

    private let fontNames = [
        "SF Mono",
        "Menlo",
        "Courier New",
        "SF Pro",
        "Helvetica Neue",
        "Georgia",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Message Font")
                .font(.headline)

            Picker("Font", selection: $fontName) {
                ForEach(fontNames, id: \.self) { name in
                    Text(name)
                        .font(.custom(name, size: 14))
                        .tag(name)
                }
            }
            .pickerStyle(.menu)

            VStack(alignment: .leading, spacing: 4) {
                Text("Size: \(Int(fontSize))pt")
                    .font(.subheadline)
                Slider(value: $fontSize, in: 10...24, step: 1)
            }

            // Live preview
            Text("The quick brown fox jumps over the lazy dog.")
                .font(.custom(fontName, size: fontSize))
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding()
        .frame(width: 280)
    }
}
