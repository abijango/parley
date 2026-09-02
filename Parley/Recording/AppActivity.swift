import Foundation

/// Derived high-level app state for the menu bar and Record badge.
enum AppActivity: Equatable {
    case recording
    /// Idle debounce before background queues drain.
    case settling(remaining: Int)
    /// Offline speaker pass or Claude summary running.
    case processing(kind: ProcessingKind, detail: String?)
    /// No live capture and nothing actively processing (held jobs still idle).
    case idle

    enum ProcessingKind: Equatable {
        case speakerPass
        case summary
    }

    var statusText: String {
        switch self {
        case .recording:
            return "Recording"
        case .settling(let remaining):
            return "Idle — speaker pass in \(remaining)s"
        case .processing(.speakerPass, let detail):
            if let detail, !detail.isEmpty { return "Speaker pass · \(detail)" }
            return "Speaker pass"
        case .processing(.summary, let detail):
            if let detail, !detail.isEmpty { return "Summarizing · \(detail)" }
            return "Summarizing"
        case .idle:
            return "Ready"
        }
    }
}
