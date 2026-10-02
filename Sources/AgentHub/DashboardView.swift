import SwiftUI
import HubCore

struct DashboardView: View {
    @EnvironmentObject var engine: Engine
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                let snap = engine.snapshot()
                
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300))], spacing: 20) {
                    ForEach(engine.config.harnesses) { harness in
                        harnessCard(harness, snap: snap)
                    }
                }
                
                HStack(spacing: 20) {
                    VStack {
                        Text("Sessions")
                            .font(.headline)
                        Text("\(engine.sessions.count) / \(engine.config.limits.maxMainSessions)")
                            .font(.largeTitle.monospacedDigit())
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                    
                    let runningJobs = engine.jobs.filter { $0.state == .running }.count
                    VStack {
                        Text("Jobs")
                            .font(.headline)
                        Text("\(runningJobs) / \(engine.config.limits.maxJobs)")
                            .font(.largeTitle.monospacedDigit())
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                }
                
                VStack(alignment: .leading) {
                    Text("Policy Explanations")
                        .font(.headline)
                    ForEach(engine.explain, id: \.self) { line in
                        Text(line)
                            .font(.caption)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading) {
                        Text("Recent Handoffs")
                            .font(.headline)
                        if engine.handoffs.isEmpty {
                            ContentUnavailableView("No handoffs yet", systemImage: "arrow.right.arrow.left")
                        } else {
                            ForEach(engine.handoffs.prefix(5)) { h in
                                VStack(alignment: .leading) {
                                    Text("\(h.fromHarness) -> \(h.toModel)")
                                    Text(h.project).font(.caption).foregroundColor(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    VStack(alignment: .leading) {
                        Text("Recent Log")
                            .font(.headline)
                        if engine.log.isEmpty {
                            ContentUnavailableView("No logs", systemImage: "doc.text")
                        } else {
                            ForEach(engine.log.suffix(5).reversed(), id: \.self) { line in
                                Text(line)
                                    .font(.caption.monospacedDigit())
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
    }
    
    @ViewBuilder
    func harnessCard(_ harness: Harness, snap: Snapshot) -> some View {
        let band = PolicyEngine.band(snap, harness.id)
        let left = PolicyEngine.left(snap, harness.id)
        let reading = engine.usage[harness.id]
        
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(harness.name)
                    .font(.headline)
                Spacer()
                BandBadge(band: band)
            }
            
            UsageBar(left: left, band: band)
            
            if let reading = reading, left != nil || reading.coolingUntil != nil {
                if let cooling = reading.coolingUntil, cooling > Date() {
                    Text("Cooling until \(cooling, style: .time)")
                        .foregroundColor(.red)
                        .font(.caption)
                } else {
                    ForEach(reading.windows, id: \.name) { w in
                        HStack {
                            Text(w.name)
                            Spacer()
                            Text("\(Int(w.usedPercent))% used")
                                .monospacedDigit()
                            if let r = w.resetsAt {
                                Text("resets \(relativeDate(r))")
                                    .foregroundColor(.secondary)
                            }
                        }
                        .font(.caption)
                    }
                }
            } else {
                Text("Usage unknown · treated as healthy")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}
