import SwiftUI
import HubCore
import AppKit

struct SessionsView: View {
    @EnvironmentObject var engine: Engine
    @State private var selection: MainSession.ID?
    @State private var error: Error?
    @State private var isNewSession = false
    @State private var sendMessageSession: MainSession?
    
    var body: some View {
        let snap = engine.snapshot()
        VStack {
            Table(engine.sessions, selection: $selection) {
                TableColumn("Harness", value: \.harness)
                TableColumn("Model") { s in Text(s.model ?? "-") }
                TableColumn("Project") { s in
                    Text(URL(fileURLWithPath: s.cwd).lastPathComponent)
                        .help(s.cwd)
                }
                TableColumn("State") { s in Text(PolicyEngine.state(snap, s).rawValue) }
                TableColumn("Last Seen") { s in Text(relativeDate(s.lastSeen)) }
                TableColumn("Warned") { s in Text(relativeDate(s.warned)) }
            }
            .contextMenu(forSelectionType: MainSession.ID.self) { items in
                if let sel = items.first, let s = engine.sessions.first(where: { $0.id == sel }) {
                    Button("Send message...") { sendMessageSession = s }
                    Menu("Hand off to...") {
                        Button("Best available") {
                            do { try engine.handoff(session: s, to: nil) } catch { self.error = error }
                        }
                        ForEach(engine.config.models.filter { $0.isMain && $0.enabled }, id: \.qualifiedID) { m in
                            Button("\(m.name) (\(m.qualifiedID))") {
                                do { try engine.handoff(session: s, to: m.qualifiedID) } catch { self.error = error }
                            }
                        }
                    }
                    Button("Wrap up now") {
                        do { try engine.wrapUpNow(session: s) } catch { self.error = error }
                    }
                }
            }
            
            HStack {
                Button("New main session...") { isNewSession = true }
                Spacer()
            }
            .padding()
        }
        .errorAlert(error: $error)
        .sheet(isPresented: $isNewSession) {
            NewSessionSheet(isPresented: $isNewSession)
        }
        .sheet(item: $sendMessageSession) { s in
            SendMessageSheet(session: s, isPresented: Binding(get: { sendMessageSession != nil }, set: { if !$0 { sendMessageSession = nil } }))
        }
    }
}

struct SendMessageSheet: View {
    @EnvironmentObject var engine: Engine
    let session: MainSession
    @Binding var isPresented: Bool
    @State private var text = ""
    @State private var kind: MessageKind = .message
    @State private var error: Error?
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Send Message")
                .font(.headline)
            Picker("Kind", selection: $kind) {
                Text("Message").tag(MessageKind.message)
                Text("Task").tag(MessageKind.task)
            }
            .pickerStyle(.segmented)
            
            TextEditor(text: $text)
                .frame(minHeight: 100)
                .border(Color.secondary)
            
            HStack {
                Button("Cancel") { isPresented = false }
                Spacer()
                Button("Send") {
                    do {
                        try engine.send(session: session, text: text, kind: kind)
                        isPresented = false
                    } catch {
                        self.error = error
                    }
                }
                .disabled(text.isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
        .errorAlert(error: $error)
    }
}

struct NewSessionSheet: View {
    @EnvironmentObject var engine: Engine
    @Binding var isPresented: Bool
    @State private var modelId: String = ""
    @State private var project: String = ""
    @State private var error: Error?
    
    var body: some View {
        Form {
            Picker("Main Model", selection: $modelId) {
                ForEach(engine.config.models.filter { $0.isMain }, id: \.qualifiedID) { m in
                    Text("\(m.name) (\(m.qualifiedID))").tag(m.qualifiedID)
                }
            }
            
            HStack {
                TextField("Project Folder", text: $project)
                Button("Browse...") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    if panel.runModal() == .OK {
                        project = panel.url?.path ?? ""
                    }
                }
            }
            
            let canStart = engine.canStartMain(modelId)
            if !canStart.ok {
                Text(canStart.reason)
                    .foregroundColor(.red)
                    .font(.caption)
            }
            
            HStack {
                Button("Cancel") { isPresented = false }
                Spacer()
                Button("Start") {
                    do {
                        try engine.startMain(modelId: modelId, project: project)
                        isPresented = false
                    } catch {
                        self.error = error
                    }
                }
                .disabled(!canStart.ok || project.isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
        .onAppear {
            if let first = engine.config.models.first(where: { $0.isMain }) {
                modelId = first.qualifiedID
            }
        }
        .errorAlert(error: $error)
    }
}
