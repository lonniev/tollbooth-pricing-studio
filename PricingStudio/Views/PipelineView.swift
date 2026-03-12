import SwiftUI

struct PipelineView: View {
    let steps: [PipelineStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Pricing Pipeline")
                .font(.title3.bold())
                .padding(.bottom, 16)

            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                HStack(alignment: .top, spacing: 16) {
                    // Connector
                    VStack(spacing: 0) {
                        Circle()
                            .fill(.tint)
                            .frame(width: 12, height: 12)

                        if index < steps.count - 1 {
                            Rectangle()
                                .fill(.tint.opacity(0.3))
                                .frame(width: 2)
                                .frame(minHeight: 60)
                        }
                    }
                    .frame(width: 12)

                    PipelineStepCard(step: step)
                        .padding(.bottom, index < steps.count - 1 ? 8 : 0)
                }
            }
        }
    }
}
