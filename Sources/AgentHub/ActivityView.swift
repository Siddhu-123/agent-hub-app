import SwiftUI
import HubCore

struct ActivityView: View {
    @EnvironmentObject var engine: Engine
    @State private var events: [ActivityEvent] = []
    @State private var filter = "All"
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var filtered: [ActivityEvent] {
        let prefixes = ["Jobs": "job.", "Masked": "masked.", "Policy": "policy.", "Sessions": "session."]
        return events.reversed().filter { filter == "All" || $0.kind.hasPrefix(prefixes[filter] ?? "") }
    }

    private func percent(_ passed: Int, _ total: Int) -> String {
        total == 0 ? "—" : String(format: "%.0f%%", Double(passed) / Double(total) * 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let stats = Activity.stats(events)
            let started = stats.models.values.reduce(0) { $0 + $1.started }
            let verified = stats.models.values.reduce(0) { $0 + $1.verified }
            HStack(spacing: 24) {
                Text("Verified \(percent(verified, started))")
                Text("Masked pass \(percent(stats.masked.passed, stats.masked.attempted))")
                Text("Fallbacks \(stats.masked.fallbacks)")
                Text("Handoffs \(stats.handoffs)")
                Spacer()
            }
            .font(.headline)
            Picker("Kind", selection: $filter) {
                ForEach(["All", "Jobs", "Masked", "Policy", "Sessions"], id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
            List(Array(filtered.enumerated()), id: \.offset) { _, event in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(event.ts, style: .time).foregroundStyle(.secondary)
                        Text(event.kind).fontWeight(.medium)
                        Spacer()
                        Text(event.model ?? "").foregroundStyle(.secondary)
                    }
                    if let job = event.job { Text(job).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    Text(event.detail.keys.sorted().map { "\($0)=\(event.detail[$0]!)" }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }
            .overlay {
                if filtered.isEmpty { ContentUnavailableView("No activity", systemImage: "waveform.path") }
            }
        }
        .padding()
        .onAppear { refresh() }
        .onReceive(timer) { _ in refresh() }
    }

    private func refresh() { events = Activity.read(paths: engine.paths) }
}
