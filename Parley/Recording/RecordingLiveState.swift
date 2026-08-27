import Foundation
import Combine

/// Live recording UI state — capture status and word count. Meters live on
/// `meters`; the timeline lives on `segmentStore`. Views must observe those
/// objects directly so a meter tick does not rebuild the record pane.
@MainActor
final class RecordingLiveState: ObservableObject {
    @Published var state: RecordingState = .idle
    let segmentStore = LiveSegmentStore()
    let meters = RecordingMeterState()
    @Published var liveWordCount = 0
    /// Session-scoped mic gain mode (Regular by default). Persists for the
    /// session until the user changes it — Start/Resume no longer force Regular.
    @Published var micInputMode: MicInputMode = .regular
    @Published var recordingStarted: Date?

    var segments: [Segment] { segmentStore.segments }
    var isRecording: Bool { state == .recording }
}