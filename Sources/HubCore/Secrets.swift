import Foundation

/// Credential detection shared by every module that sends text to a model. Owned by the orchestrator.
public enum Secrets {
    static let pattern = try! NSRegularExpression(pattern:
        #"(?i)(?:\b(?:password|passwd|secret|api[_ -]?key|access[_ -]?token|refresh[_ -]?token)\s*[:=]\s*\S+|\b(?:sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AIza[0-9A-Za-z_-]{30,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|ya29\.[A-Za-z0-9_-]{15,}|GOCSPX-[A-Za-z0-9_-]{10,}|Bearer\s+[A-Za-z0-9._-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----))"#)

    public static let sensitiveNames: Set<String> = [".env", ".env.local", "credentials.json", "token.json", "client_secret.json", "id_rsa", "id_ed25519"]

    public static func contains(_ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Throws HubError.secret when any text looks like a credential.
    public static func assertClean(_ texts: [String]) throws {
        if texts.contains(where: contains) { throw HubError.secret }
    }
}

public enum HubError: Error, Equatable, LocalizedError {
    case secret
    case invalid(String)
    case notFound(String)
    case noCapacity(String)

    public var errorDescription: String? {
        switch self {
        case .secret: return "Blocked: the text looks like it contains a credential"
        case .invalid(let m), .notFound(let m), .noCapacity(let m): return m
        }
    }
}
