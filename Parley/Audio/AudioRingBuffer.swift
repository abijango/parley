import Foundation
import os

/// Single-producer / single-consumer ring buffer of Float samples.
///
/// The producer is a real-time audio callback (mic tap block or Core Audio IO
/// proc): it must never allocate or block, so `write` only does index math plus
/// a `memcpy` under a brief `os_unfair_lock`. On overflow it drops the OLDEST
/// samples — a callback must not stall for a slow consumer.
///
/// `Atomic` (Synchronization) would be the lock-free choice; the critical section
/// is a few index updates plus one copy, so the unfair lock is held only briefly.
final class AudioRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private var writeIndex = 0
    private var readIndex = 0
    private var filled = 0
    private let lock = OSAllocatedUnfairLock()

    init(capacity: Int) {
        self.capacity = capacity
        self.storage = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        self.storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    /// Real-time safe. Copies `samples` in, dropping oldest data on overflow.
    func write(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, !samples.isEmpty else { return }
        let count = samples.count
        lock.lock()
        defer { lock.unlock() }

        // If the incoming chunk exceeds capacity, keep only its tail.
        var src = base
        var n = count
        if n > capacity {
            src = base + (n - capacity)
            n = capacity
        }

        let firstChunk = min(n, capacity - writeIndex)
        storage.advanced(by: writeIndex).update(from: src, count: firstChunk)
        if n > firstChunk {
            storage.update(from: src + firstChunk, count: n - firstChunk)
        }
        writeIndex = (writeIndex + n) % capacity

        filled += n
        if filled > capacity {
            // Dropped oldest: advance readIndex to keep the most recent `capacity`.
            let overflow = filled - capacity
            readIndex = (readIndex + overflow) % capacity
            filled = capacity
        }
    }

    /// Consumer side (not real-time). Drains up to `maxCount` samples into `out`.
    /// Returns the number of samples read.
    @discardableResult
    func read(maxCount: Int, into out: inout [Float]) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let n = min(maxCount, filled)
        if n == 0 { return 0 }
        if out.count < n { out = [Float](repeating: 0, count: n) }

        out.withUnsafeMutableBufferPointer { dst in
            guard let d = dst.baseAddress else { return }
            let firstChunk = min(n, capacity - readIndex)
            d.update(from: storage.advanced(by: readIndex), count: firstChunk)
            if n > firstChunk {
                (d + firstChunk).update(from: storage, count: n - firstChunk)
            }
        }
        readIndex = (readIndex + n) % capacity
        filled -= n
        return n
    }

    var availableToRead: Int {
        lock.lock(); defer { lock.unlock() }
        return filled
    }

    /// Drain both rings and sum into one mono buffer, anchored to the mic ring as the
    /// real-time clock (the mic tap runs continuously at 16 kHz even during silence).
    /// Reading the system ring only up to the mic's count keeps the mixed stream at true
    /// real-time length. `max()` plus zero-padding would over-count when the rings are
    /// out of phase, stretching the ASR timeline out of sync with the clean mixed file.
    /// The per-tick cap lets a backlog clear over about a second instead of one huge read.
    static func mixLive(mic: AudioRingBuffer, system: AudioRingBuffer, maxSamples: Int = 16_000) -> [Float]? {
        let n = min(mic.availableToRead, maxSamples)
        guard n > 0 else { return nil }
        var out = [Float](), sysBuf = [Float]()
        let rm = mic.read(maxCount: n, into: &out)
        guard rm > 0 else { return nil }
        out.removeSubrange(rm...)
        let rs = system.read(maxCount: rm, into: &sysBuf)
        for i in 0..<rs { out[i] += sysBuf[i] }
        for i in 0..<rm { out[i] = max(-1, min(1, out[i])) }
        return out
    }
}
