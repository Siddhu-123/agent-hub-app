import Foundation
import Testing
@testable import HubCore

@Test func pathsHonourOverride() {
    #expect(HubPaths(root: URL(fileURLWithPath: "/tmp/x")).config.path == "/tmp/x/config.json")
}
