import Foundation

/// Claimed for detection and naming. Parsers wait on a live MeetingProbe dump.
final class WebexSource: MeetingSource, @unchecked Sendable {
    static let identity = SourceIdentity(
        displayName: "Webex",
        matchers: [.exact("cisco-systems.spark"), .exact("com.cisco.webexmeetingsapp")],
        capability: .none)

    required init(call: CallIdentity) { _ = call }

    func read(_ context: ScanContext) -> SourceReading {
        SourceReading(title: nil, roster: .unreadable(at: context.now))
    }
}
