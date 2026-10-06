import Foundation
import Testing
@testable import HubCore

@Test func closedWorkerStdinDoesNotTerminateParent() {
    let result = Proc.run(["sh", "-c", "exec 0<&-; exit 7"],
                          stdin: String(repeating: "prompt", count: 200_000),
                          timeout: 5,
                          onStart: { _ in Thread.sleep(forTimeInterval: 0.1) })
    // Let the asynchronous writer observe the closed pipe before this test exits.
    Thread.sleep(forTimeInterval: 0.1)
    #expect(result.exitCode == 7)
    #expect(!result.timedOut)
}

@Test func fillBasicSubstitution() {
    #expect(Proc.fill(["--model", "{model}"], ["model": "m1"]) == ["--model", "m1"])
}

@Test func fillNoDoubleExpansion() {
    let values = ["prompt": "say claude and claude-haiku-4-5-20251001"]
    let result = Proc.fill(["--prompt", "{prompt}"], values)
    #expect(result == ["--prompt", "say claude and claude-haiku-4-5-20251001"])
}

@Test func fillMultiplePlaceholdersInOneArg() {
    let values = ["model": "m", "unknown": "u"]
    let result = Proc.fill(["a{model}b{unknown}"], values)
    #expect(result == ["ambu"])
}

@Test func fillUnknownPlaceholderStaysAsIs() {
    let result = Proc.fill(["a{model}b{unknown}"], ["model": "m"])
    #expect(result == ["amb{unknown}"])
}

@Test func fillUnmatchedBraceAtEndIsKept() {
    let result = Proc.fill(["test{"], [:])
    #expect(result == ["test{"])
}

@Test func fillUnmatchedBraceInMiddleIsKept() {
    let result = Proc.fill(["te{st"], [:])
    #expect(result == ["te{st"])
}

@Test func fillEmptyBracesAreKept() {
    let result = Proc.fill(["a{}b"], ["": "replacement"])
    #expect(result == ["areplacementb"])
}

@Test func fillMultipleArgsWithMixedPlaceholders() {
    let values = ["exe": "/bin/x", "prompt": "say claude and claude-haiku-4-5-20251001", "model": "m"]
    let result = Proc.fill(["exe", "-p", "{prompt}"], values)
    #expect(result == ["exe", "-p", "say claude and claude-haiku-4-5-20251001"])
}

@Test func fillWithRepeatedPlaceholder() {
    let result = Proc.fill(["{x}{x}"], ["x": "a"])
    #expect(result == ["aa"])
}

@Test func fillPlaceholderAtStart() {
    let result = Proc.fill(["{model}test"], ["model": "m"])
    #expect(result == ["mtest"])
}

@Test func fillPlaceholderAtEnd() {
    let result = Proc.fill(["test{model}"], ["model": "m"])
    #expect(result == ["testm"])
}

@Test func fillNoPlaceholders() {
    let result = Proc.fill(["no", "placeholders", "here"], ["model": "m"])
    #expect(result == ["no", "placeholders", "here"])
}

@Test func fillEmptyTemplate() {
    let result = Proc.fill([], ["model": "m"])
    #expect(result == [])
}

@Test func fillValuesAreNotReExpanded() {
    let result = Proc.fill(["{prompt} {model}"], ["prompt": "use {model}", "model": "m"])
    #expect(result == ["use {model} m"])
}

@Test func fillNestedBraceReplacesInnerPlaceholder() {
    #expect(Proc.fill(["{{model}}"], ["model": "m"]) == ["{m}"])
}

@Test func fillCrossReferencingValuesExpandOnce() {
    #expect(Proc.fill(["{a}", "{b}"], ["a": "{b}", "b": "{a}"]) == ["{b}", "{a}"])
}
