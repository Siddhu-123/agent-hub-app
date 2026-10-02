import SwiftUI
import HubCore

struct ModelsView: View {
    @EnvironmentObject var engine: Engine
    @State private var draft: AppConfig?
    @State private var saveError: Error?
    @State private var isAddingMain = false
    
    var body: some View {
        VStack {
            if let draft = draft {
                let binding = Binding(get: { draft }, set: { self.draft = $0 })
                
                Table(binding.models) {
                    TableColumn("ID") { b in TextField("", text: b.id) }
                    TableColumn("Name") { b in TextField("", text: b.name) }
                    TableColumn("Harness") { b in
                        Picker("", selection: b.harness) {
                            ForEach(draft.harnesses) { h in
                                Text(h.name).tag(h.id)
                            }
                        }
                    }
                    TableColumn("Intell.") { b in
                        HStack {
                            Slider(value: Binding(get: { Double(b.wrappedValue.intelligence) }, set: { b.wrappedValue.intelligence = Int($0) }), in: 0...100)
                            Text("\(b.wrappedValue.intelligence)")
                                .monospacedDigit()
                        }
                    }
                    TableColumn("Effort") { b in TextField("Optional", text: Binding(get: { b.wrappedValue.effort ?? "" }, set: { b.wrappedValue.effort = $0.isEmpty ? nil : $0 })) }
                    TableColumn("Toggles") { b in
                        HStack {
                            Toggle("M", isOn: b.isMain).help("Main")
                            Toggle("W", isOn: b.isWorker).help("Worker")
                            Toggle("F", isOn: b.free).help("Free")
                            Toggle("E", isOn: b.enabled).help("Enabled")
                        }
                    }
                    TableColumn("Action") { b in
                        Button("Del") {
                            self.draft?.models.removeAll { $0.id == b.wrappedValue.id }
                        }
                    }
                }
                
                Divider()
                
                HStack {
                    Text("Main Order:")
                    List {
                        ForEach(binding.mainOrder, id: \.self) { b in
                            Text(b.wrappedValue)
                        }
                        .onMove { indices, newOffset in
                            self.draft?.mainOrder.move(fromOffsets: indices, toOffset: newOffset)
                        }
                    }
                    .frame(height: 100)
                }
                
                HStack {
                    Button("Add Model") {
                        self.draft?.models.append(ModelEntry(id: "new-\(UUID().uuidString.prefix(4))", harness: "claude", name: "New", intelligence: 50, isMain: false, isWorker: true))
                    }
                    Button("Add Main Model...") {
                        isAddingMain = true
                    }
                    
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
        .sheet(isPresented: $isAddingMain) {
            AddMainModelSheet(draft: Binding(get: { draft ?? engine.config }, set: { draft = $0 }), isPresented: $isAddingMain)
        }
    }
}

struct AddMainModelSheet: View {
    @Binding var draft: AppConfig
    @Binding var isPresented: Bool
    @State private var newModel = ModelEntry(id: "", harness: "claude", name: "", intelligence: 50, isMain: true, isWorker: false)
    
    var body: some View {
        Form {
            TextField("ID", text: $newModel.id)
            TextField("Name", text: $newModel.name)
            Picker("Harness", selection: $newModel.harness) {
                ForEach(draft.harnesses) { h in
                    Text(h.name).tag(h.id)
                }
            }
            HStack {
                Text("Intelligence")
                Slider(value: Binding(get: { Double(newModel.intelligence) }, set: { newModel.intelligence = Int($0) }), in: 0...100)
                Text("\(newModel.intelligence)")
                    .monospacedDigit()
            }
            HStack {
                Button("Cancel") { isPresented = false }
                Spacer()
                Button("Add") {
                    ConfigStore.addMainModel(&draft, model: newModel)
                    isPresented = false
                }
                .disabled(newModel.id.isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }
}
