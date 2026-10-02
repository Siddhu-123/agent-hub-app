import SwiftUI
import HubCore
import AppKit

struct SettingsView: View {
    @EnvironmentObject var engine: Engine
    @State private var draft: AppConfig?
    @State private var installError: Error?
    @State private var hookMessage: String?
    @AppStorage("launchNotch") private var launchNotch: Bool = true
    
    var body: some View {
        Form {
            if let draft = draft {
                let binding = Binding(get: { draft }, set: { self.draft = $0 })
                
                Section("Limits") {
                    Stepper("Max Main Sessions: \(draft.limits.maxMainSessions)", value: binding.limits.maxMainSessions, in: 1...12)
                    Stepper("Max Jobs: \(draft.limits.maxJobs)", value: binding.limits.maxJobs, in: 0...16)
                    
                    VStack(alignment: .leading) {
                        Text("Band Thresholds")
                            .font(.headline)
                        
                        HStack {
                            Text("Exhausted: \(Int(draft.limits.exhaustedAtOrBelow * 100))%")
                                .frame(width: 150, alignment: .leading)
                            Slider(value: binding.limits.exhaustedAtOrBelow, in: 0...1)
                        }
                        HStack {
                            Text("Wrap Up: \(Int(draft.limits.wrapUpBelow * 100))%")
                                .frame(width: 150, alignment: .leading)
                            Slider(value: binding.limits.wrapUpBelow, in: 0...1)
                        }
                        HStack {
                            Text("Single: \(Int(draft.limits.singleSessionBelow * 100))%")
                                .frame(width: 150, alignment: .leading)
                            Slider(value: binding.limits.singleSessionBelow, in: 0...1)
                        }
                        HStack {
                            Text("Reduced: \(Int(draft.limits.sameHarnessMinLeft * 100))%")
                                .frame(width: 150, alignment: .leading)
                            Slider(value: binding.limits.sameHarnessMinLeft, in: 0...1)
                        }
                        
                        // Live band-threshold preview bar
                        GeometryReader { geo in
                            let w = geo.size.width
                            ZStack(alignment: .leading) {
                                Rectangle().fill(Band.healthy.color)
                                Rectangle().fill(Band.reduced.color).frame(width: w * draft.limits.sameHarnessMinLeft)
                                Rectangle().fill(Band.single.color).frame(width: w * draft.limits.singleSessionBelow)
                                Rectangle().fill(Band.wrapUp.color).frame(width: w * draft.limits.wrapUpBelow)
                                Rectangle().fill(Band.exhausted.color).frame(width: w * draft.limits.exhaustedAtOrBelow)
                            }
                        }
                        .frame(height: 20)
                        .cornerRadius(4)
                    }
                    
                    HStack {
                        Text("Grace Seconds")
                        TextField("", value: binding.limits.graceSeconds, format: .number)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Text("Active Seconds")
                        TextField("", value: binding.limits.activeSeconds, format: .number)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Text("Timeout Seconds")
                        TextField("", value: binding.limits.jobTimeoutSeconds, format: .number)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                
                Section("General") {
                    Toggle("Auto Launch", isOn: binding.autoLaunch)
                    TextField("Terminal App", text: binding.terminalApp)
                    Toggle("Launch Notch with Agent Hub", isOn: $launchNotch)
                }
                
                Section("Integrations") {
                    HStack {
                        Button("Install hooks") {
                            do { try engine.installHooks() } catch { installError = error }
                        }
                        Button("Install command-line tool") {
                            do { try engine.installCLI() } catch { installError = error }
                        }
                        Button("Uninstall hooks") {
                            do { try engine.uninstallHooks() } catch { installError = error }
                        }
                    }
                    
                    HStack {
                        Button("Install status line") {
                            do { hookMessage = try engine.installStatusLine(force: false) } catch { installError = error }
                        }
                        Button("Replace existing") {
                            do { hookMessage = try engine.installStatusLine(force: true) } catch { installError = error }
                        }
                    }
                    
                    if let hookMessage = hookMessage {
                        Text(hookMessage).font(.caption).foregroundColor(.secondary)
                    }
                    
                    VStack(alignment: .leading) {
                        Text("Hook Status:")
                        if let c = engine.hookStatus["claude"] {
                            Text("Claude: \(c ? "Installed" : "Not installed")")
                        }
                        if let c = engine.hookStatus["codex"] {
                            Text("Codex: \(c ? "Installed" : "Not installed")")
                        }
                    }
                    .font(.caption)
                    
                    Button("Open data folder") {
                        NSWorkspace.shared.open(engine.paths.root)
                    }
                }
                
                HStack {
                    Spacer()
                    Button("Save") {
                        do {
                            try engine.saveConfig(draft)
                        } catch {
                            installError = error
                        }
                    }
                    .disabled(draft == engine.config)
                    
                    Button("Revert") {
                        self.draft = engine.config
                    }
                    .disabled(draft == engine.config)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            draft = engine.config
        }
        .onChange(of: engine.config) { _, new in
            draft = new
        }
        .errorAlert(error: $installError)
    }
}
