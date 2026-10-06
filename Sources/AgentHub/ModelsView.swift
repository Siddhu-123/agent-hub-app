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
                
                ModelsTable(draft: Binding(get: { self.draft ?? draft }, set: { self.draft = $0 }), modelToDelete: $modelToDelete)
                
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
                        if var current = self.draft {
                            ConfigStore.upsertModel(ModelEntry(id: newId, harness: harness, name: "New Model", intelligence: 50, isMain: false, isWorker: true), in: &current)
                            self.draft = current
                        }
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
                    ConfigStore.removeModel(id: target.id, harness: target.harness, from: &currentDraft)
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

private struct ModelsTable: View {
    @Binding var draft: AppConfig
    @Binding var modelToDelete: ModelEntry?

    /// Rows keyed by harness/id: the same model id may exist in two harnesses.
    struct ModelRow: Identifiable { let id: String; let index: Int }
    private var rows: [ModelRow] { draft.models.indices.map { ModelRow(id: draft.models[$0].qualifiedID, index: $0) } }

    var body: some View {
        Table(rows) {
            deleteColumn
            idColumn
            nameColumn
            harnessColumn
            intelligenceColumn
            effortColumn
            togglesColumn
            brokerColumn
        }
    }

    private var deleteColumn: some TableColumnContent<ModelRow, Never> {
        TableColumn("") { row in let model = $draft.models[row.index];
            Button(role: .destructive) {
                modelToDelete = model.wrappedValue
            } label: {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
            .help("Delete model")
        }
        .width(min: 28, ideal: 30, max: 36)
    }

    private var idColumn: some TableColumnContent<ModelRow, Never> {
        TableColumn("ID") { row in let model = $draft.models[row.index]; TextField("", text: model.id) }
            .width(min: 110, ideal: 140)
    }

    private var nameColumn: some TableColumnContent<ModelRow, Never> {
        TableColumn("Name") { row in let model = $draft.models[row.index]; TextField("", text: model.name) }
            .width(min: 100, ideal: 130)
    }

    private var harnessColumn: some TableColumnContent<ModelRow, Never> {
        TableColumn("Harness") { row in let model = $draft.models[row.index];
            Picker("", selection: model.harness) {
                ForEach(draft.harnesses) { harness in
                    Text(harness.name).tag(harness.id)
                }
            }
            .labelsHidden()
        }
        .width(min: 90, ideal: 110)
    }

    private var intelligenceColumn: some TableColumnContent<ModelRow, Never> {
        TableColumn("Intell.") { row in let model = $draft.models[row.index];
            HStack(spacing: 4) {
                Slider(value: Binding(
                    get: { Double(model.wrappedValue.intelligence) },
                    set: { model.wrappedValue.intelligence = Int($0) }
                ), in: 0...100)
                Text("\(model.wrappedValue.intelligence)")
                    .monospacedDigit()
                    .frame(width: 28, alignment: .trailing)
            }
        }
        .width(min: 95, ideal: 120)
    }

    private var effortColumn: some TableColumnContent<ModelRow, Never> {
        TableColumn("Effort") { row in let model = $draft.models[row.index];
            TextField("Optional", text: Binding(
                get: { model.wrappedValue.effort ?? "" },
                set: { model.wrappedValue.effort = $0.isEmpty ? nil : $0 }
            ))
        }
        .width(min: 65, ideal: 80)
    }

    private var togglesColumn: some TableColumnContent<ModelRow, Never> {
        TableColumn("Toggles") { row in let model = $draft.models[row.index];
            HStack(spacing: 8) {
                Toggle("Main", isOn: Binding(
                    get: { model.wrappedValue.isMain },
                    set: { newValue in
                        model.wrappedValue.isMain = newValue
                        if newValue {
                            if !draft.mainOrder.contains(model.wrappedValue.qualifiedID) {
                                draft.mainOrder.append(model.wrappedValue.qualifiedID)
                            }
                        } else {
                            draft.mainOrder.removeAll { $0 == model.wrappedValue.qualifiedID }
                        }
                    }
                ))
                .help("Main can lead sessions and receive handoffs")

                Toggle("Worker", isOn: model.isWorker)
                    .help("Worker can run delegated jobs")

                Toggle("Free", isOn: model.free)
                    .help("Free has no paid model cost")

                Toggle("Enabled", isOn: model.enabled)
                    .help("Enabled lets the hub use the model")
            }
        }
        .width(min: 240, ideal: 270)
    }

    private var brokerColumn: some TableColumnContent<ModelRow, Never> {
        TableColumn("Broker") { row in let model = $draft.models[row.index];
            Toggle("", isOn: Binding(
                get: {
                    model.wrappedValue.brokerEligible ??
                        (model.wrappedValue.isWorker &&
                         model.wrappedValue.intelligence >= draft.limits.brokerMinIntelligence &&
                         model.wrappedValue.intelligence <= draft.limits.brokerMaxIntelligence)
                },
                set: { model.wrappedValue.brokerEligible = $0 }
            ))
            .labelsHidden()
            .accessibilityLabel("Broker eligible")
            .disabled(!model.wrappedValue.enabled || !model.wrappedValue.isWorker || draft.harness(model.wrappedValue.harness)?.trusted != true)
            .help("Allow this enabled, trusted worker model to mask and decode project jobs")
        }
        .width(min: 55, ideal: 65)
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
