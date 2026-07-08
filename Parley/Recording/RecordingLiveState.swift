import Foundation
import Combine

/// Live recording UI state — segments, meters, and capture status. Views that only
/// need the transcript or meters should observe this instead of `RecordingController`.
@MainActor
final class RecordingLiveState: ObservableObject {
    @Published var state: RecordingState = .idle
    let segmentStore = LiveSegmentStore()
    @Published var liveWordCount = 0
    @Published var micLevel: Float = 0
    @Published var remoteLevel: Float = 0
    @Published var micSeemsSilent = false
    @Published var recordingStarted: Date?

    var segments: [Segment] { segmentStore.segments }
    var isRecording: Bool { state == .recording }
}