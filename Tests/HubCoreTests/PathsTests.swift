import Foundation
import Testing
@testable import HubCore

@Test func pathsHonourOverride() {
    #expect(HubPaths(root: URL(fileURLWithPath: "/tmp/x")).config.path == "/tmp/x/config.json")
}

@Test func procRunsWithTimeoutAndStdin() {
    let r = Proc.run(["cat"], stdin: "hello", timeout: 5)
    #expect(r.passed && r.output == "hello")
    let slow = Proc.run(["sleep", "5"], timeout: 0.3)
    #expect(slow.timedOut && !slow.passed)
    #expect(Proc.run(["definitely-not-a-binary-xyz"]).exitCode == 127)
}

@Test func secretsAndQuoting() {
    #expect(Secrets.contains("api_key=abcdef123456"))
    #expect(!Secrets.contains("refactor the parser"))
    #expect(Proc.quote("a'b") == "'a'\"'\"'b'")
    #expect(Proc.fill(["--model", "{model}"], ["model": "m1"]) == ["--model", "m1"])
}
