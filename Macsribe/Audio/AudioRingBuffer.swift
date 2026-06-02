import Foundation
import os

/// Single-producer / single-consumer ring buffer of Float samples.
///
/// The producer is a real-time audio callback (mic tap block or Core Audio IO
/// proc): it must never allocate or block, so `write` only does index math plus
/// a `memcpy` under a brief `os_unfair_lock`. On overflow it drops the OLDEST
/// samples — a callback must not stall for a slow consumer.
///
/// `Atomic` (Synchronization) would be the lock-free choice but it requires
/// macOS 15+; we target 14.4, so the short unfair-lock critical section is the
/// pragmatic correct option.
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
}
