import Foundation
import UserNotifications

class Notifier {
    static let shared = Notifier()
    
    func post(_ lines: [String]) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        
        for line in lines {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let text = String(parts[1])
            
            if text.hasPrefix("wrap-up:") || text.hasPrefix("handoff:") || text.hasPrefix("job verified:") || text.hasPrefix("job needs review:") || text.hasPrefix("job failed:") {
                let content = UNMutableNotificationContent()
                content.title = "Agent Hub"
                content.body = text
                content.sound = .default
                let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                UNUserNotificationCenter.current().add(req)
            }
        }
    }
}
