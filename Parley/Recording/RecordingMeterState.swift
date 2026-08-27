import Foundation
import Combine

/// High-rate input levels. Isolated from `RecordingLiveState` so meter ticks do not
/// rebuild the record pane (transcript, inspector, chrome).
@MainActor
final class RecordingMeterState: ObservableObject {
    @Published var micLevel: Float = 0
    @Published var remoteLevel: Float = 0
    @Published var micSeemsSilent = false
}
