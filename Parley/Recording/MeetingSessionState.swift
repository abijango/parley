import Foundation
import Combine

/// Per-meeting metadata fields (title, filing, attendees, notes) and AX discovery
/// suggestions. Separated from live capture state so typing in the inspector does
/// not republish segment/meter updates.
@MainActor
final class MeetingSessionState: ObservableObject {
    @Published var meetingTitle = ""
    @Published var destinationPath = ""
    @Published var attendees = ""
    @Published var manualNotes = ""

    @Published var suggestedAttendees: [SuggestedAttendee] = []
    @Published var discoveredTitle: String?
    private(set) var discoveredTitleSource: String?
    var titleSource: String?
    var titleWasUserEdited = false

    func resetDiscovery() {
        suggestedAttendees = []
        discoveredTitle = nil
        discoveredTitleSource = nil
    }

    func setDiscoveredTitle(_ title: String, source: String) {
        discoveredTitle = title
        discoveredTitleSource = source
    }

    func applyDiscoveredTitleIfAllowed(_ title: String, source: String) {
        guard !titleWasUserEdited, isDefaultTitle(meetingTitle) else { return }
        meetingTitle = title
        titleSource = source
    }

    func isDefaultTitle(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t == "Recorded call" || t.hasSuffix(" call")
    }
}