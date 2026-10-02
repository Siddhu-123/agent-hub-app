import SwiftUI
import HubCore

public extension Band {
    var color: Color {
        switch self {
        case .healthy: return .green
        case .reduced: return .yellow
        case .single: return .orange
        case .wrapUp: return .red
        case .exhausted: return .gray
        }
    }
}

public struct BandBadge: View {
    let band: Band
    public init(band: Band) { self.band = band }
    public var body: some View {
        Circle()
            .fill(band.color)
            .frame(width: 8, height: 8)
            .help("Band: \(String(describing: band))")
    }
}

public struct UsageBar: View {
    let left: Double?
    let band: Band
    public init(left: Double?, band: Band) {
        self.left = left
        self.band = band
    }
    public var body: some View {
        if let left = left {
            ProgressView(value: left)
                .progressViewStyle(.linear)
                .tint(band.color)
        } else {
            ProgressView(value: 0.0)
                .progressViewStyle(.linear)
                .tint(.gray)
                .opacity(0.5)
        }
    }
}

public func relativeDate(_ date: Date?, now: Date = Date()) -> String {
    guard let date = date else { return "Never" }
    let diff = now.timeIntervalSince(date)
    if diff < 60 { return "Just now" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: now)
}

public struct ErrorAlertModifier: ViewModifier {
    @Binding var error: Error?
    public func body(content: Content) -> some View {
        content
            .alert(isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } }), error: error.map { LocalizedAlertError(error: $0) }) { _ in
                Button("OK") {}
            } message: { err in
                if let msg = err.recoverySuggestion {
                    Text(msg)
                }
            }
    }
}

struct LocalizedAlertError: LocalizedError {
    let underlyingError: Error
    var errorDescription: String? { underlyingError.localizedDescription }
    var recoverySuggestion: String? { (underlyingError as? LocalizedError)?.recoverySuggestion }
    init(error: Error) { self.underlyingError = error }
}

public extension View {
    func errorAlert(error: Binding<Error?>) -> some View {
        modifier(ErrorAlertModifier(error: error))
    }
}
