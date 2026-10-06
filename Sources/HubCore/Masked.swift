import Foundation

public enum Masked {
    public static func denyTokens(project: String) -> [String] {
        var tokens: [String] = []
        let generic = Set(["users", "dev", "home", "private", "tmp", "var", "src", "code", "projects", "documents", "library", "application", "support", "application support", "agenthub", "worktrees", "folders", "volumes"])
        
        let url = URL(fileURLWithPath: project)
        let pathComponents = url.pathComponents
        for component in pathComponents {
            let lower = component.lowercased()
            if lower == "/" || lower.isEmpty { continue }
            if !generic.contains(lower) {
                tokens.append(lower)
                tokens += lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { !generic.contains($0) }
            }
        }
        
        if !url.lastPathComponent.isEmpty && url.lastPathComponent != "/" {
            tokens.append(url.lastPathComponent.lowercased())
        }
        
        let branchResult = Proc.run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd: project)
        if branchResult.passed {
            let branch = branchResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !branch.isEmpty && branch != "HEAD" {
                tokens.append(branch.lowercased())
            }
        }
        
        tokens.append(NSUserName().lowercased())
        
        let emailResult = Proc.run(["git", "config", "user.email"], cwd: project)
        if emailResult.passed {
            let email = emailResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !email.isEmpty {
                tokens.append(email.lowercased())
            }
        }
        
        let nameResult = Proc.run(["git", "config", "user.name"], cwd: project)
        if nameResult.passed {
            let name = nameResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                for part in name.split(separator: " ") {
                    tokens.append(String(part).lowercased())
                }
                tokens.append(name.lowercased())
            }
        }
        
        return Array(Set(tokens.filter { $0.count >= 4 })).sorted()
    }
    
    public static func scan(dir: URL, tokens: [String]) -> [String] {
        var problems: [String] = []
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            if name == "map.json" || name == "check.json" { continue }
            guard let isRegular = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile, isRegular else { continue }
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                problems.append("\(name): unreadable or binary file")
                continue
            }
            problems += scan(text: content, name: name, tokens: tokens)
        }
        return problems
    }

    public static func scan(text content: String, name: String, tokens: [String]) -> [String] {
        var problems: [String] = []
        do {
            let fileURL = URL(fileURLWithPath: name)
            let patterns = ["/Users/", "/home/", "/Volumes/", "/private/", "~/"]
            for pattern in patterns {
                if content.contains(pattern) {
                    problems.append("\(fileURL.lastPathComponent): contains \(pattern)")
                }
            }
            
            if content.range(of: #"[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, options: .regularExpression) != nil {
                problems.append("\(fileURL.lastPathComponent): contains an email address")
            }
            
            if Secrets.contains(content) {
                problems.append("\(fileURL.lastPathComponent): contains Secrets-style key patterns")
            }
            
            let lowerContent = content.lowercased()
            for token in tokens {
                if lowerContent.contains(token) {
                    problems.append("\(fileURL.lastPathComponent): contains token \(token)")
                }
            }
        }
        return problems
    }

    /// Check output for a retry, with the masked directories shown as "." and withheld entirely if anything private remains.
    public static func feedback(_ output: String, dirs: [String], tokens: [String]) -> String {
        var text = String(output.suffix(1500))
        for dir in dirs.sorted(by: { $0.count > $1.count }) {
            for spelling in [dir, URL(fileURLWithPath: dir).resolvingSymlinksInPath().path] { text = text.replacingOccurrences(of: spelling, with: ".") }
        }
        return scan(text: text, name: "output", tokens: tokens).isEmpty ? text : "(output withheld)"
    }

    public static func retryPrompt(_ base: String, feedback: String) -> String {
        """
        \(base)

        Your previous attempt is already in the files, but the check failed:
        \(feedback)
        Fix the files so the check passes.
        """
    }

    public static func maskPrompt(job: Job, runDir: String, maskDir: String) -> String {
        """
        MASK step for an external worker that must never learn anything about this project.
        Project (read only, never modify it): \(runDir)
        Objective: \(job.objective)
        Allowed files (relative to the project): \(job.allowedFiles.joined(separator: ", "))
        Real acceptance argv: \(job.checkArgv.joined(separator: " "))

        Write into \(maskDir):
        - brief.md: a self-contained generic task describing exactly the work to do, where every project name, product, person, company, path, URL, email, key and domain identifier is replaced by neutral placeholders (P1, P2...). Include the expected behaviour precisely enough to implement it without the project.
        - files/<flat basename>: masked copies of only the files the worker needs to read or edit (same placeholders). No subfolders.
        - map.json: {"placeholders":{"P1":"original"},"classes":{"P1":"name|path|url|email|domain|key|identifier"},"files":{"basename":"real relative path"}}
        - check.json: a JSON argv array run inside files/ that verifies the generic work without the project (for example ["sh","check.sh"] with check.sh in files/, or ["python3","test_x.py"]). It must not need network or anything outside files/.
        Do not copy secrets, credentials or personal data. Do not edit the project.
        """
    }

    public static func heavyPrompt(brief: String, files: [String]) -> String {
        """
        \(brief)

        Files in the current directory you may read and edit: \(files.joined(separator: ", ")).
        Edit only those files. You may run shell commands (for example the tests) in the current directory only; a check runs after you finish.
        """
    }

    public static func decodePrompt(job: Job, runDir: String, maskDir: String) -> String {
        """
        DECODE step. An external worker solved a masked copy of this task.
        Objective: \(job.objective)
        Masked files before the worker: \(maskDir)/masked-original/
        Masked files after the worker: \(maskDir)/files/
        Placeholder and file map: \(maskDir)/map.json
        Apply the worker's changes to the real files in \(runDir), reversing the placeholders, and fix anything that does not fit the real project.
        Edit only these files: \(job.allowedFiles.joined(separator: ", ")).
        Then run the acceptance argv and make it pass: \(job.checkArgv.joined(separator: " "))
        Do not commit.
        """
    }

    static let maskClasses: Set<String> = ["name", "path", "url", "email", "domain", "key", "identifier"]

    /// The classes of values the broker masked: its own labels when valid, else classified from the originals.
    public static func classes(placeholders: [String: String], labels: [String: String]?) -> [String] {
        var found = Set<String>()
        for (p, original) in placeholders {
            if let l = labels?[p]?.lowercased(), maskClasses.contains(l) { found.insert(l); continue }
            let v = original.trimmingCharacters(in: .whitespaces)
            if Secrets.contains(v) { found.insert("key") }
            else if v.contains("://") { found.insert("url") }
            else if v.contains("@") && v.contains(".") { found.insert("email") }
            else if v.contains("/") || v.hasPrefix("~") { found.insert("path") }
            else if v.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil && !v.contains(" ") { found.insert("domain") }
            else if v.contains(" ") || v.first?.isUppercase == true { found.insert("name") }
            else { found.insert("identifier") }
        }
        return found.sorted()
    }
}
