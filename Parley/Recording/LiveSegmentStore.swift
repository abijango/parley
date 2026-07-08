import Foundation
import Combine

/// Observable live transcript timeline with surgical updates instead of replacing
/// the whole `[Segment]` array on every ASR tick.
@MainActor
final class LiveSegmentStore: ObservableObject {
    @Published private(set) var segments: [Segment] = []

    func reset() {
        guard !segments.isEmpty else { return }
        segments = []
    }

    /// Apply the engine's merged timeline, touching only changed tail rows when possible.
    func apply(_ merged: [Segment]) {
        if merged.isEmpty {
            if !segments.isEmpty { segments = [] }
            return
        }
        if segments.isEmpty {
            segments = merged
            return
        }

        // Same row count and stable ids — update only changed elements in place.
        if merged.count == segments.count,
           zip(merged, segments).allSatisfy({ $0.0.id == $0.1.id }) {
            var copy = segments
            var changed = false
            for i in merged.indices where copy[i] != merged[i] {
                copy[i] = merged[i]
                changed = true
            }
            if changed { segments = copy }
            return
        }

        // Append-only growth with an unchanged prefix (common confirm path).
        if merged.count > segments.count {
            let prefix = segments.count
            if merged.prefix(prefix).map(\.id) == segments.map(\.id) {
                var copy = segments
                copy.append(contentsOf: merged.suffix(merged.count - prefix))
                segments = copy
                return
            }
        }

        // Volatile tail: same prefix, last row same id but revised text/timing.
        if merged.count == segments.count,
           merged.dropLast().map(\.id) == segments.dropLast().map(\.id),
           let last = merged.last, segments.last?.id == last.id,
           segments.last != last {
            var copy = segments
            copy[copy.count - 1] = last
            segments = copy
            return
        }

        if segments != merged {
            segments = merged
        }
    }
}