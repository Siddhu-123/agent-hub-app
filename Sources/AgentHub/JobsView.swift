import SwiftUI
import HubCore
import AppKit

struct JobsView: View {
    @EnvironmentObject var engine: Engine
    @State private var selection: Job.ID?
    @State private var error: Error?
    @State private var isNewJob = false
    
    var body: some View {
        HSplitView {
            VStack {
                Table(engine.jobs, selection: $selection) {
                    TableColumn("State") { j in
                        Text(j.state.rawValue)
                    }
                    TableColumn("ID", value: \.id)
                    TableColumn("Worker") { j in Text(j.model ?? "-") }
                    TableColumn("Project") { j in Text(URL(fileURLWithPath: j.project).lastPathComponent) }
                    TableColumn("Created") { j in Text(relativeDate(j.created)) }
                    TableColumn("Gate") { j in
                        if let g = j.gate {
                            let passed = g.passed(for: j.kind)
                            Text(passed ? "Pass" : "Fail").foregroundColor(passed ? .green : .red)
                        } else {
                            Text("-")
                        }
                    }
                    TableColumn("Changed Files") { j in
                        if let g = j.gate {
                            Text("\(g.changedFiles.count)")
                        } else {
                            Text("-")
                        }
                    }
                }
                .contextMenu(forSelectionType: Job.ID.self) { items in
                    if let sel = items.first, let j = engine.jobs.first(where: { $0.id == sel }) {
                        if j.state == .queued || j.state == .running {
                            Button("Cancel") { engine.cancel(jobId: j.id) }
                        }
                        if j.state == .verified && j.worktree != nil {
                            Button("Merge worktree") {
                                do { try engine.merge(jobId: j.id) } catch { self.error = error }
                            }
                        }
                        Button("Re-run") {
                            do { try engine.rerun(jobId: j.id) } catch { self.error = error }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                HStack {
                    Button("New job...") { isNewJob = true }
                    Spacer()
                }
                .padding()
            }
            .frame(minWidth: 450, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            
            if let sel = selection, let j = engine.jobs.first(where: { $0.id == sel }) {
                JobDetailView(job: j)
                    .frame(minWidth: 250)
            } else {
                ContentUnavailableView("Select a job", systemImage: "mouse")
                    .frame(minWidth: 250)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .errorAlert(error: $error)
        .sheet(isPresented: $isNewJob) {
            NewJobSheet(isPresented: $isNewJob)
        }
    }
}

struct JobDetailView: View {
    let job: Job
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Objective").font(.headline)
                Text(job.objective).font(.body)
                
                Divider()
                
                Text("Attempts (\(job.attempts.count))").font(.headline)
                ForEach(Array(job.attempts.enumerated()), id: \.offset) { _, a in
                    Text("\(a.harness)/\(a.model): \(a.result)")
                        .font(.caption)
                }
                
                if let gate = job.gate {
                    Divider()
                    Text("Gate Result").font(.headline)
                    Text("Changed: \(gate.changedFiles.joined(separator: ", "))").font(.caption)
                    Text("Outside Allowed: \(gate.outsideAllowed.joined(separator: ", "))").font(.caption).foregroundColor(gate.outsideAllowed.isEmpty ? .primary : .red)
                    Text("Acceptance Output:").font(.caption)
                    ScrollView(.horizontal) {
                        Text(gate.acceptance.output)
                            .font(.caption.monospaced())
                    }
                }
                
                if let out = job.output {
                    Divider()
                    Text("Output").font(.headline)
                    Text(out)
                        .font(.caption.monospaced())
                }
            }
            .padding()
        }
    }
}

struct NewJobSheet: View {
    @EnvironmentObject var engine: Engine
    @Binding var isPresented: Bool
    
    @State private var project: String = ""
    @State private var objective: String = ""
    @State private var allowedFilesRaw: String = ""
    @State private var checkArgvRaw: String = "[\"sh\", \"scripts/swift.sh\", \"build\", \"--disable-sandbox\"]"
    @State private var size: JobSize = .routine
    @State private var kind: JobKind = .implement
    @State private var privacy: Privacy = .project
    @State private var isolation: Isolation = .checkout
    @State private var mainModel: String = "" // Optional
    @State private var error: Error?
    
    struct LocalAppError: LocalizedError {
        let errorDescription: String?
    }
    
    var body: some View {
        Form {
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
            
            Section("Objective") {
                TextEditor(text: $objective)
                    .frame(height: 100)
            }
            
            Section("Allowed Files (one per line)") {
                TextEditor(text: $allowedFilesRaw)
                    .frame(height: 80)
            }
            
            TextField("Acceptance Argv (JSON Array)", text: $checkArgvRaw)
                .foregroundColor(isValidJSON(checkArgvRaw) ? .primary : .red)
            
            Picker("Size", selection: $size) {
                ForEach(JobSize.allCases, id: \.self) { s in Text(s.rawValue).tag(s) }
            }
            Picker("Kind", selection: $kind) {
                ForEach(JobKind.allCases, id: \.self) { k in Text(k.rawValue).tag(k) }
            }
            Picker("Privacy", selection: $privacy) {
                ForEach(Privacy.allCases, id: \.self) { p in Text(p.rawValue).tag(p) }
            }
            
            Toggle("Worktree Isolation", isOn: Binding(get: { isolation == .worktree }, set: { isolation = $0 ? .worktree : .checkout }))
            
            Picker("Delegating Main Model (optional)", selection: $mainModel) {
                Text("None").tag("")
                ForEach(engine.config.models.filter { $0.isMain }) { m in
                    Text(m.name).tag(m.id)
                }
            }
            
            HStack {
                Button("Cancel") { isPresented = false }
                Spacer()
                Button("Create Job") {
                    do {
                        guard let argv = try? JSONDecoder().decode([String].self, from: Data(checkArgvRaw.utf8)) else {
                            throw LocalAppError(errorDescription: "Invalid checkArgv JSON")
                        }
                        let files = allowedFilesRaw.components(separatedBy: .newlines).filter { !$0.isEmpty }
                        let j = Job(project: project, objective: objective, allowedFiles: files, checkArgv: argv, size: size, kind: kind, privacy: privacy, isolation: isolation, mainModel: mainModel.isEmpty ? nil : mainModel, created: Date())
                        try engine.delegate(j)
                        isPresented = false
                    } catch {
                        self.error = error
                    }
                }
                .disabled(project.isEmpty || objective.isEmpty || !isValidJSON(checkArgvRaw))
            }
        }
        .padding()
        .frame(width: 500, height: 600)
        .errorAlert(error: $error)
    }
    
    func isValidJSON(_ text: String) -> Bool {
        if let data = text.data(using: .utf8), let _ = try? JSONDecoder().decode([String].self, from: data) {
            return true
        }
        return false
    }
}
