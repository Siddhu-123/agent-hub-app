import SwiftUI
import HubCore
import UserNotifications

@main
struct AgentHubApp: App {
    @StateObject private var engine: Engine
    
    init() {
        let bundlePath = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/agenthubctl")
        let siblingPath = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("agenthubctl")
        let ctlPath = FileManager.default.fileExists(atPath: bundlePath.path) ? bundlePath.path : (siblingPath?.path ?? "/usr/local/bin/agenthubctl")
        let e = Engine(ctlPath: ctlPath)
        e.onLog = { Notifier.shared.post($0) }
        _engine = StateObject(wrappedValue: e)
        e.start()
        
        if ProcessInfo.processInfo.environment["AGENT_HUB_TEST"] == nil {
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    e.stop()
                }
            }
            
            UserDefaults.standard.register(defaults: ["launchNotch": true])
            let launchNotch = UserDefaults.standard.bool(forKey: "launchNotch")
            let notchRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == HubPaths.notchBundleID }
            if launchNotch && !notchRunning {
                if let notchURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: HubPaths.notchBundleID) {
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = false
                    NSWorkspace.shared.openApplication(at: notchURL, configuration: config) { _, _ in }
                }
            }
        }
        
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }
    
    var body: some Scene {
        Window("Agent Hub", id: "main") {
            MainWindow()
                .environmentObject(engine)
        }
        
        MenuBarExtra("Agent Hub", systemImage: "circle.hexagongrid") {
            MenuBarView()
                .environmentObject(engine)
        }
        .menuBarExtraStyle(.window)
    }
}
