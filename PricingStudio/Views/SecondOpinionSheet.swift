import SwiftUI

/// Sheet presenting a streaming second-opinion review of a pricing campaign.
struct SecondOpinionSheet: View {
    @Bindable var viewModel: SecondOpinionViewModel
    var onSave: ((String) -> Void)?
    var onRerun: (() -> Void)?

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
                ScrollView {
                    if let error = viewModel.error {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(.red)
                            Text(error)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else if viewModel.reviewText.isEmpty && !viewModel.isStreaming {
                        VStack(spacing: 12) {
                            Image(systemName: "person.2.wave.2")
                                .font(.system(size: 36))
                                .foregroundStyle(.secondary)
                            Text("Tap Re-run to request a fresh review")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else {
                        MarkdownContentView(text: viewModel.reviewText)
                            .textSelection(.enabled)
                            .padding()
                    }

                    if viewModel.isStreaming {
                        ProgressView("Analyzing campaign...")
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
}
