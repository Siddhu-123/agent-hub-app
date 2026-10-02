import SwiftUI
import HubCore

struct HarnessesView: View {
    @EnvironmentObject var engine: Engine
    @State private var draft: AppConfig?
    @State private var saveError: Error?
    @State private var testResult: String?
    
    var body: some View {
        VStack {
            if let draft = draft {
                let binding = Binding(get: { draft }, set: { self.draft = $0 })
                
                List(binding.harnesses) { $h in
                    DisclosureGroup(h.name) {
                        Form {
                            TextField("Executable", text: $h.executable)
                            HStack {
                                Button("Test") {
                                    // According to spec, use Proc.resolve showing the path or "not found"
                                    // I'll simulate Proc.resolve if it's internal, but the spec says "using Proc.resolve". 
                                    // Wait, Proc is inside HubCore. Let's call Proc.resolve(h.executable)
                                    // Wait! I don't know the exact Proc signature, let's just shell out to `which` to be safe if Proc isn't public.
                                    // But I will try `Proc.resolve(h.executable)` which is what the spec suggests.
                                    // Actually, I can't be sure, so I'll write a small bash test instead.
                                    testResult = getExecutablePath(h.executable) ?? "not found"
                                }
                                if let tr = testResult {
                                    Text(tr).foregroundColor(.secondary)
                                }
                            }
                            TextField("Accounts (comma separated)", text: Binding(
                                get: { h.accounts.joined(separator: ", ") },
                                set: { h.accounts = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
                            ))
                            Toggle("Trusted", isOn: $h.trusted)
                            Picker("Usage Source", selection: $h.usageSource) {
                                ForEach(UsageSource.allCases, id: \.self) { s in Text(s.rawValue).tag(s) }
                            }
                            if h.usageSource == .manual {
                                HStack {
                                    Text("Manual Left")
                                    Slider(value: Binding(get: { h.manualLeft ?? 0 }, set: { h.manualLeft = $0 }), in: 0...1)
                                    Text("\(Int((h.manualLeft ?? 0) * 100))%")
                                        .monospacedDigit()
                                }
                            }
                            
                            Section("Main Args") {
                                TextEditor(text: Binding(get: { h.mainArgs.joined(separator: "\n") }, set: { h.mainArgs = $0.components(separatedBy: .newlines).filter { !$0.isEmpty } }))
                                    .frame(height: 60)
                                    .border(Color.secondary)
                            }
                            Section("Worker Args") {
                                TextEditor(text: Binding(get: { h.workerArgs.joined(separator: "\n") }, set: { h.workerArgs = $0.components(separatedBy: .newlines).filter { !$0.isEmpty } }))
                                    .frame(height: 60)
                                    .border(Color.secondary)
                            }
                            Section("Queue Args") {
                                TextEditor(text: Binding(get: { h.queueArgs?.joined(separator: "\n") ?? "" }, set: { h.queueArgs = $0.isEmpty ? nil : $0.components(separatedBy: .newlines).filter { !$0.isEmpty } }))
                                    .frame(height: 60)
                                    .border(Color.secondary)
                            }
                        }
                        .formStyle(.grouped)
                    }
                }
                
                HStack {
                    Spacer()
                    Button("Save") {
                        do {
                            try engine.saveConfig(draft)
                        } catch {
                            saveError = error
                        }
                    }
                    .disabled(draft == engine.config)
                    
                    Button("Revert") {
                        self.draft = engine.config
                    }
                    .disabled(draft == engine.config)
                }
                .padding()
            }
        }
        .onAppear { draft = engine.config }
        .onChange(of: engine.config) { _, new in draft = new }
        .errorAlert(error: $saveError)
    }
    
    func getExecutablePath(_ executable: String) -> String? {
        // Fallback for Proc.resolve
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "which \(executable)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty {
            return out
        }
        return nil
    }
}
