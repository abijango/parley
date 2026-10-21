import Foundation

/// Shared error / availability types for summary backends.
enum SummaryAvailability: Equatable {
    case available
    case unavailable(String)

    var isAvailable: Bool { if case .available = self { return true }; return false }
    var reason: String? { if case .unavailable(let r) = self { return r }; return nil }
}

enum SummaryError: LocalizedError {
    case engineUnavailable(String)
    case generationFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .engineUnavailable(let m): return m
        case .generationFailed(let m): return m
        case .cancelled: return "Cancelled."
        }
    }
}
