import SwiftUI

/// Sheet presenting a structured second-opinion review of a pricing campaign.
/// The full response is collected behind the scenes and rendered all at once
/// with section-level formatting, verdict badges, and a revision prompt.
struct SecondOpinionSheet: View {
    @Bindable var viewModel: SecondOpinionViewModel
    var onSave: ((String) -> Void)?
    var onRerun: (() -> Void)?
    var onRevise: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Provider badge
                HStack {
                    Label(viewModel.providerName, systemImage: "brain.head.profile")
                        .font(.caption.bold())
                        .foregroundStyle(viewModel.providerName == "Grok" ? .orange : .purple)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            (viewModel.providerName == "Grok" ? Color.orange : Color.purple)
                                .opacity(0.12)
                        )
                        .clipShape(Capsule())

                    Spacer()

                    if !viewModel.isStreaming && !viewModel.reviewText.isEmpty {
                        Button {
                            onSave?(viewModel.reviewText)
                        } label: {
                            Label("Save", systemImage: "square.and.arrow.down")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider()

                // Content
                if viewModel.isStreaming {
                    // Loading state — collecting response behind the scenes
                    Spacer()
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Getting \(viewModel.providerName)'s take...")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("Analyzing your campaign and preparing a structured critique.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    Spacer()
                } else if let error = viewModel.error {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    Spacer()
                } else if viewModel.sections.isEmpty && viewModel.reviewText.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "person.2.wave.2")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text("Tap Re-run to request a fresh review")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    Spacer()
                } else if !viewModel.sections.isEmpty {
                    // Structured section display
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(viewModel.sections) { section in
                                sectionCard(section)
                            }

                            // Revision prompt
                            if viewModel.hasSuggestedChanges {
                                revisionPrompt
                            }
                        }
                        .padding()
                    }
                } else {
                    // Fallback: raw markdown if section parsing didn't find headings
                    ScrollView {
                        MarkdownContentView(text: viewModel.reviewText)
                            .textSelection(.enabled)
                            .padding()
                    }
                }
            }
            .navigationTitle("Second Opinion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        onRerun?()
                    } label: {
                        Label("Re-run", systemImage: "arrow.clockwise")
                    }
                    .disabled(viewModel.isStreaming)
                }
            }
        }
    }

    // MARK: - Section Card

    @ViewBuilder
    private func sectionCard(_ section: SecondOpinionViewModel.ReviewSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section header
            HStack(spacing: 8) {
                Image(systemName: section.icon)
                    .font(.subheadline)
                    .foregroundStyle(iconColor(for: section))
                Text(section.title)
                    .font(.subheadline.bold())

                Spacer()

                // Verdict badge
                if let verdict = section.verdict {
                    verdictBadge(verdict)
                }
            }

            // Section content
            MarkdownContentView(text: section.content)
                .textSelection(.enabled)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
        )
    }

    private func iconColor(for section: SecondOpinionViewModel.ReviewSection) -> Color {
        switch section.icon {
        case "checkmark.seal.fill": return .green
        case "exclamationmark.triangle.fill": return .orange
        case "lightbulb.fill": return .yellow
        case "chart.line.uptrend.xyaxis": return .blue
        case "gavel.fill":
            switch section.verdict {
            case .approve: return .green
            case .approveWithReservations: return .yellow
            case .reworkRecommended: return .orange
            case .reject: return .red
            case nil: return .secondary
            }
        default: return .secondary
        }
    }

    @ViewBuilder
    private func verdictBadge(_ verdict: SecondOpinionViewModel.ReviewSection.Verdict) -> some View {
        let (text, color): (String, Color) = {
            switch verdict {
            case .approve: return ("APPROVE", .green)
            case .approveWithReservations: return ("WITH RESERVATIONS", .yellow)
            case .reworkRecommended: return ("REWORK", .orange)
            case .reject: return ("REJECT", .red)
            }
        }()

        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }

    // MARK: - Revision Prompt

    @ViewBuilder
    private var revisionPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                Text("\(viewModel.providerName) suggests changes")
                    .font(.subheadline.bold())
            }

            Text("Would you like to revise your campaign based on these suggestions? This will start a new interview fork incorporating the reviewer's feedback.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                onRevise?(viewModel.suggestedChangesText)
                dismiss()
            } label: {
                Label("Revise Campaign as Suggested", systemImage: "pencil.and.outline")
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.regular)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
                )
        )
    }
}
