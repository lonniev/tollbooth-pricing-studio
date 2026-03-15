import SwiftUI

struct PipelineView: View {
    @Binding var steps: [PipelineStep]
    let isEditing: Bool

    @State private var showingAddSheet = false
    @State private var editingStep: PipelineStep?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Constraints")
                .font(.title3.bold())
                .padding(.bottom, 16)

            if steps.isEmpty && !isEditing {
                Text("No constraints configured")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                stepList
            }

            if isEditing {
                Button {
                    showingAddSheet = true
                } label: {
                    Label("Add Constraint", systemImage: "plus.circle.fill")
                        .font(.subheadline)
                }
                .padding(.top, 12)
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddConstraintSheet { type, params in
                withAnimation {
                    steps.append(PipelineStep.create(type: type, params: params))
                }
            }
        }
        .sheet(item: $editingStep) { step in
            if let spec = ConstraintCatalog.spec(for: step.displayType) {
                ConstraintParamEditor(
                    spec: spec,
                    existingParams: step.params,
                    onSave: { newParams in
                        if let idx = steps.firstIndex(where: { $0.id == step.id }) {
                            steps[idx] = PipelineStep.create(type: step.type, params: newParams)
                        }
                    }
                )
            }
        }
    }

    private var stepList: some View {
        let items = Array(steps)
        return ForEach(items.indices, id: \.self) { index in
            let step = items[index]
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 0) {
                    Circle()
                        .fill(.tint)
                        .frame(width: 12, height: 12)

                    if index < items.count - 1 {
                        Rectangle()
                            .fill(.tint.opacity(0.3))
                            .frame(width: 2)
                            .frame(minHeight: 60)
                    }
                }
                .frame(width: 12)

                HStack {
                    PipelineStepCard(step: step)
                        .padding(.bottom, index < items.count - 1 ? 8 : 0)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if isEditing {
                                editingStep = step
                            }
                        }

                    if isEditing {
                        Button(role: .destructive) {
                            withAnimation {
                                steps.removeAll { $0.id == step.id }
                            }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                                .imageScale(.large)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .onMove { source, destination in
            if isEditing {
                steps.move(fromOffsets: source, toOffset: destination)
            }
        }
    }
}
