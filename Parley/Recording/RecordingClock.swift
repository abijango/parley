import Foundation

/// Single shared wall-clock anchor for a recording session.
///
/// The core drift bug in any dual-stream transcriber: each audio pipeline times
/// segments by its own accumulated sample count, and the two counts diverge over
/// a long meeting (dropped buffers, differing start latency). We avoid that by
/// stamping every captured audio buffer with its arrival time relative to ONE
/// anchor taken at record-start. Segment times are then derived from buffer
/// arrival times, never from a pipeline's internal clock.
final class RecordingClock: @unchecked Sendable {
    private let startHostTime: UInt64
    private let ticksToSeconds: Double

    init() {
        self.startHostTime = DispatchTime.now().uptimeNanoseconds
        self.ticksToSeconds = 1.0 / 1_000_000_000.0
    }

    /// Seconds elapsed since record-start, "now".
    func elapsed() -> TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        return Double(now &- startHostTime) * ticksToSeconds
    }

    /// Seconds since record-start for a specific host time (nanoseconds, from
    /// `DispatchTime.now().uptimeNanoseconds` captured in a callback).
    func elapsed(atHostTimeNanos hostTime: UInt64) -> TimeInterval {
        Double(hostTime &- startHostTime) * ticksToSeconds
    }
}
