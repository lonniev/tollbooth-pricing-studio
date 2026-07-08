import Charts
import SwiftUI

/// Per-relay diagnostics: live connection health, an on-demand ping/health
/// check, and a chart of DMs sent/received via this relay over time.
struct RelayView: View {
    let relay: String

    @State private var trafficStore = RelayTrafficStore.shared
    @State private var subManager = RelaySubscriptionManager.shared
    @State private var pinging = false
    @State private var pingResult: NostrRelayService.RelayPingResult?
    @State private var rangeHours = 24

    private var url: URL? { URL(string: relay) }
    private var host: String { url?.host ?? relay }

    private var buckets: [RelayTrafficStore.Bucket] {
        trafficStore.series(for: relay, hours: rangeHours)
    }
    private var totals: (sent: Int, received: Int) {
        trafficStore.totals(for: relay)
    }
    private var liveState: PersistentRelayConnection.ConnectionState? {
        guard let url else { return nil }
        return subManager.connectionStates[url]
    }
    private var hasTraffic: Bool { totals.sent + totals.received > 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                healthSection
                trafficSection
            }
            .padding()
        }
        .navigationTitle(host)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(liveColor)
                    .frame(width: 10, height: 10)
                Text(liveLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(liveColor)
            }
            Text(relay)
                .font(.footnote)
                .monospaced()
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Health / Ping

    private var healthSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Health Check")
                .font(.headline)

            Button {
                runPing()
            } label: {
                HStack {
                    if pinging {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "wave.3.right")
                    }
                    Text(pinging ? "Pinging…" : "Run Health Check")
                }
            }
            .buttonStyle(.bordered)
            .disabled(pinging || url == nil)

            if let result = pingResult {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: result.online ? "checkmark.seal.fill" : "xmark.octagon.fill")
                        .foregroundStyle(result.online ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.online ? "Online" : "Unreachable")
                            .font(.subheadline.weight(.semibold))
                        Text(result.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: - Traffic

    private var trafficSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("DM Traffic")
                    .font(.headline)
                Spacer()
                Picker("Range", selection: $rangeHours) {
                    Text("24h").tag(24)
                    Text("3d").tag(72)
                    Text("7d").tag(168)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }

            HStack(spacing: 16) {
                statTile(label: "Sent", value: totals.sent, color: .blue)
                statTile(label: "Received", value: totals.received, color: .green)
            }

            if hasTraffic {
                Chart(buckets) { bucket in
                    BarMark(
                        x: .value("Time", bucket.date, unit: .hour),
                        y: .value("Count", bucket.sent)
                    )
                    .foregroundStyle(by: .value("Direction", "Sent"))

                    BarMark(
                        x: .value("Time", bucket.date, unit: .hour),
                        y: .value("Count", bucket.received)
                    )
                    .foregroundStyle(by: .value("Direction", "Received"))
                }
                .chartForegroundStyleScale(["Sent": Color.blue, "Received": Color.green])
                .chartLegend(position: .bottom)
                .frame(height: 220)
            } else {
                ContentUnavailableView(
                    "No traffic yet",
                    systemImage: "chart.bar",
                    description: Text("DMs sent to and received from this relay will appear here.")
                )
                .frame(height: 220)
            }
        }
    }

    private func statTile(label: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Actions

    private func runPing() {
        guard let url else { return }
        pinging = true
        pingResult = nil
        Task {
            let result = await NostrRelayService.ping(url)
            pingResult = result
            pinging = false
        }
    }

    // MARK: - Live-state presentation

    private var liveColor: Color {
        switch liveState {
        case .connected: return .green
        case .connecting: return .yellow
        case .reconnecting: return .orange
        case .disconnected: return .red
        case .none: return .secondary
        }
    }

    private var liveLabel: String {
        switch liveState {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .disconnected: return "Disconnected"
        case .none: return "Not subscribed"
        }
    }
}
