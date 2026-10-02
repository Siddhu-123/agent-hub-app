import SwiftUI
import HubCore
import AppKit

struct MenuBarView: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.openWindow) var openWindow
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(engine.config.harnesses) { harness in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(harness.name)
                            .font(.headline)
                        Spacer()
                        let left = PolicyEngine.left(engine.snapshot(), harness.id)
                        if let l = left {
                            Text("\(Int(l * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                    }
                    UsageBar(left: PolicyEngine.left(engine.snapshot(), harness.id), band: engine.band(harness.id))
                }
            }
            
            Divider()
            
            HStack {
                Text("\(engine.sessions.count) / \(engine.config.limits.maxMainSessions) sessions")
                Spacer()
                let running = engine.jobs.filter { $0.state == .running }.count
                let queued = engine.jobs.filter { $0.state == .queued }.count
                Text("\(running) running / \(queued) queued jobs")
            }
            .font(.caption)
            
            Divider()
            
            VStack(alignment: .leading) {
                ForEach(engine.log.suffix(5).reversed(), id: \.self) { line in
                    Text(line)
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundColor(.secondary)
                }
            }
            
            Divider()
            
            HStack {
                Button("Open Hub") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Tick now") {
                    engine.tick()
                }
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding()
        .frame(width: 300)
    }
}
