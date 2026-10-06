import Foundation

/// A delegate receipt: the job JSON plus the fields every receipt carries, even when unset.
public enum Receipt {
    public static func of(_ j: Job, config: AppConfig) throws -> [String: Any] {
        var r = (try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(j)) as? [String: Any]) ?? [:]
        let worker = j.model.flatMap { config.model($0) }
        r["model"] = j.model ?? NSNull()
        r["zdr"] = j.zdr ?? worker?.isZDR ?? false
        r["masked"] = j.masked ?? false
        r["maskedClasses"] = j.maskedClasses ?? []
        r["gate"] = r["gate"] ?? NSNull()
        r["gatePassed"] = j.gate.map { $0.passed(for: j.kind) } ?? NSNull()
        r["note"] = j.note ?? ""
        r["permissionDenials"] = j.permissionDenials ?? []
        return r
    }
}
