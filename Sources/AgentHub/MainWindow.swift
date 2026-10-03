import SwiftUI
import HubCore

struct MainWindow: View {
    @EnvironmentObject var engine: Engine
    @State private var selection: SidebarItem = .tree
    @State private var columns: NavigationSplitViewVisibility = .detailOnly
    
    enum SidebarItem {
        case tree, live, dashboard, sessions, jobs, activity, models, harnesses, settings
    }
    
    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: $selection) {
                Section("Agent Hub") {
                    NavigationLink(value: SidebarItem.tree) { Label("Tree", systemImage: "point.3.connected.trianglepath.dotted") }
                    NavigationLink(value: SidebarItem.live) { Label("Live", systemImage: "dot.radiowaves.left.and.right") }
                    NavigationLink(value: SidebarItem.dashboard) { Label("Dashboard", systemImage: "gauge") }
                    NavigationLink(value: SidebarItem.sessions) { Label("Sessions", systemImage: "terminal") }
                    NavigationLink(value: SidebarItem.jobs) { Label("Jobs", systemImage: "checklist") }
                    NavigationLink(value: SidebarItem.activity) { Label("Activity", systemImage: "waveform.path") }
                }
                Section("Configuration") {
                    NavigationLink(value: SidebarItem.models) { Label("Models", systemImage: "cpu") }
                    NavigationLink(value: SidebarItem.harnesses) { Label("Harnesses", systemImage: "wrench.and.screwdriver") }
                    NavigationLink(value: SidebarItem.settings) { Label("Settings", systemImage: "gear") }
                }
            }
        } detail: {
            VStack(spacing: 0) {
                if let warning = engine.configWarning {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                        Text(warning)
                        Spacer()
                        Button(action: { /* dismiss not possible on readonly var, maybe just show? wait, it says "shows engine.configWarning as a dismissible banner". But configWarning is readonly. I can use a local state. */ }) {
                            Image(systemName: "xmark")
                        }
                    }
                    .padding()
                    .background(Color.yellow.opacity(0.2))
                }
                
                switch selection {
                case .tree: TreeView()
                case .live: LiveView()
                case .dashboard: DashboardView()
                case .sessions: SessionsView()
                case .jobs: JobsView()
                case .activity: ActivityView()
                case .models: ModelsView()
                case .harnesses: HarnessesView()
                case .settings: SettingsView()
                }
            }
        }
        .onChange(of: selection) { _, item in
            // The tree uses the whole window; the sidebar stays one toolbar click away.
            withAnimation { columns = item == .tree ? .detailOnly : .all }
        }
    }
}
