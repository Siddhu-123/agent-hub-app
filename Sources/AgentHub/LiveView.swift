import SwiftUI
import HubCore

struct LiveView: View {
    @EnvironmentObject var engine: Engine

    private let harnesses: [(key: String, name: String)] = [
        ("claude", "Claude Code"),
        ("codex", "Codex"),
        ("antigravity", "Antigravity"),
        ("opencode", "OpenCode")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !engine.liveRequests.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Pending Requests")
                            .font(.headline)
                        ForEach(engine.liveRequests, id: \.id) { req in
                            requestCard(req)
                        }
                    }
                    .padding(.bottom, 8)
                }

                if engine.liveSessions.isEmpty {
                    ContentUnavailableView("No agent sessions right now", systemImage: "dot.radiowaves.left.and.right")
                        .padding(.top, 40)
                } else {
                    ForEach(harnesses, id: \.key) { harness in
                        let sessions = engine.liveSessions.filter { $0.platform == harness.key }
                        if !sessions.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(harness.name)
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                                ForEach(sessions, id: \.sessionId) { session in
                                    sessionRow(session)
                                }
                            }
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func requestCard(_ req: LiveRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(req.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(req.platformName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if !req.detail.isEmpty {
                Text(req.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                if req.canAnswer {
                    Button("Allow") {
                        engine.respond(req, decision: "allow")
                    }
                    .buttonStyle(.borderedProminent)

                    if req.options.contains("always") {
                        Button("Always") {
                            engine.respond(req, decision: "always")
                        }
                    }

                    Button("Deny") {
                        engine.respond(req, decision: "deny")
                    }
                } else {
                    Text("Answer in the app")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func sessionRow(_ session: LiveSession) -> some View {
        HStack(alignment: .center, spacing: 12) {
            statusDot(session.status)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(session.title.isEmpty ? "Untitled" : session.title)
                        .font(.body.weight(.medium))
                    Spacer()
                    Text(elapsedString(session: session))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }

                if !session.activity.isEmpty {
                    Text(session.activity)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 12) {
                    if let project = session.project, !project.isEmpty {
                        Label(project, systemImage: "folder")
                    }
                    if let model = session.model, !model.isEmpty {
                        Label(model, systemImage: "cpu")
                    }
                    Text("\(session.steps) step\(session.steps == 1 ? "" : "s")")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private func statusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "working": return .green
        case "waiting": return .orange
        case "idle": return .gray
        case "done": return .blue
        case "error": return .red
        default: return .gray
        }
    }

    @ViewBuilder
    private func statusDot(_ status: String) -> some View {
        Circle()
            .fill(statusColor(status))
            .frame(width: 10, height: 10)
            .help("Status: \(status)")
    }

    private func elapsedString(session: LiveSession) -> String {
        let referenceTime = session.turnStartedAt ?? session.startedAt
        let elapsed = max(0, Int(Date().timeIntervalSince1970 - referenceTime))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        if minutes > 0 {
            return String(format: "%dm %02ds", minutes, seconds)
        } else {
            return String(format: "%ds", seconds)
        }
    }
}
