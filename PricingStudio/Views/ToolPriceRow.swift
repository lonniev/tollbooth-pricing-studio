import SwiftUI

struct ToolPriceRow: View {
    let tool: ToolPrice
    @State private var showingInfo = false

    var body: some View {
        HStack(spacing: 12) {
            Text(tool.toolName)
                .font(.subheadline.monospaced())

            if !tool.intent.isEmpty {
                Button {
                    showingInfo.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingInfo) {
                    Text(tool.intent)
                        .font(.callout)
                        .padding()
                        .frame(idealWidth: 260)
                        .presentationCompactAdaptation(.popover)
                }
            }

            Spacer()

            priceBadge
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var priceBadge: some View {
        if tool.priceSats == 0 {
            Text("FREE")
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.green.opacity(0.15), in: Capsule())
                .foregroundStyle(.green)
        } else {
            Text("\(tool.priceSats) sat\(tool.priceSats == 1 ? "" : "s")")
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.orange.opacity(0.15), in: Capsule())
                .foregroundStyle(.orange)
        }
    }
}
