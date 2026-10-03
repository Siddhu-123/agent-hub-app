import SwiftUI
import HubCore

struct ModelsView: View {
    @EnvironmentObject var engine: Engine
    @State private var draft: AppConfig?
    @State private var saveError: Error?
    @State private var isAddingMain = false
    @State private var modelToDelete: ModelEntry?
    
    var body: some View {
        VStack(spacing: 0) {
            if let draft = draft {
                let binding = Binding(get: { draft }, set: { self.draft = $0 })
                
                Table(binding.models) {
                    TableColumn("") { b in
                        Button(role: .destructive) {
                            modelToDelete = b.wrappedValue
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .help("Delete model")
                    }
                    .width(min: 28, ideal: 30, max: 36)

                    TableColumn("ID") { b in TextField("", text: b.id) }
                        .width(min: 110, ideal: 140)

                    TableColumn("Name") { b in TextField("", text: b.name) }
                        .width(min: 100, ideal: 130)

                    TableColumn("Harness") { b in
                        Picker("", selection: b.harness) {
                            ForEach(draft.harnesses) { h in
                                Text(h.name).tag(h.id)
                            }
                        }
                        .labelsHidden()
                    }
                    .width(min: 90, ideal: 110)

                    TableColumn("Intell.") { b in
                        HStack(spacing: 4) {
                            Slider(value: Binding(get: { Double(b.wrappedValue.intelligence) }, set: { b.wrappedValue.intelligence = Int($0) }), in: 0...100)
                            Text("\(b.wrappedValue.intelligence)")
                                .monospacedDigit()
                                .frame(width: 28, alignment: .trailing)
                        }
                    }
                    .width(min: 95, ideal: 120)

                    TableColumn("Effort") { b in
                        TextField("Optional", text: Binding(get: { b.wrappedValue.effort ?? "" }, set: { b.wrappedValue.effort = $0.isEmpty ? nil : $0 }))
                    }
                    .width(min: 65, ideal: 80)

                    TableColumn("Toggles") { b in
                        HStack(spacing: 8) {
                            Toggle("Main", isOn: Binding(
                                get: { b.wrappedValue.isMain },
                                set: { newValue in
                                    b.wrappedValue.isMain = newValue
                                    if newValue {
                                        if !(self.draft?.mainOrder.contains(b.wrappedValue.id) ?? false) {
                                            self.draft?.mainOrder.append(b.wrappedValue.id)
                                        }
                                    } else {
                                        self.draft?.mainOrder.removeAll { $0 == b.wrappedValue.id }
                                    }
                                }
                            ))
                            .help("Main can lead sessions and receive handoffs")

                            Toggle("Worker", isOn: b.isWorker)
                                .help("Worker can run delegated jobs")

                            Toggle("Free", isOn: b.free)
                                .help("Free has no paid model cost")

                            Toggle("Enabled", isOn: b.enabled)
                                .help("Enabled lets the hub use the model")
                        }
                    }
                    .width(min: 240, ideal: 270)
                }
                
                Divider()
                
                HStack(alignment: .top) {
                    Text("Main Order:")
                        .font(.headline)
                        .padding(.top, 4)
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
                .padding(.horizontal)
                .padding(.top, 8)
                
                HStack {
                    Button {
                        let newId = "new-\(UUID().uuidString.prefix(4).lowercased())"
                        let harness = draft.harnesses.first?.id ?? "claude"
                        self.draft?.models.append(ModelEntry(id: newId, harness: harness, name: "New Model", intelligence: 50, isMain: false, isWorker: true))
                    } label: {
                        Label("Add Model", systemImage: "plus")
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
        .confirmationDialog(
            "Delete Model",
            isPresented: Binding(
                get: { modelToDelete != nil },
                set: { if !$0 { modelToDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: modelToDelete
        ) { target in
            Button("Delete '\(target.id)'", role: .destructive) {
                if var currentDraft = draft {
                    ConfigStore.removeModel(id: target.id, from: &currentDraft)
                    draft = currentDraft
                }
                modelToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                modelToDelete = nil
            }
        } message: { target in
            Text("Are you sure you want to remove model '\(target.name.isEmpty ? target.id : target.name)' (\(target.id))? This will also remove it from Main Order.")
        }
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
