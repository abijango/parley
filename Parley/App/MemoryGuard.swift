import Foundation

/// System-memory inspection used to guard heavy model loads.
///
/// The app loads ONE shared Whisper model (both track pipelines share the same
/// `WhisperKit` instance), so the risk isn't "two large models at once" — it's
/// loading a large model on a RAM-starved Mac, or compiling it while the system
/// is already thrashing swap. The latter is exactly what corrupted the
/// CoreML/MPSGraph cache before (a compile interrupted by memory pressure leaves
/// a half-written `model_0.mpsgraph`). Rather than silently inviting that crash,
/// we report the condition so the UI can warn and the user can switch models or
/// free memory first.
enum MemoryGuard {
    /// Total physical RAM on this Mac.
    static var physicalRAM: UInt64 { ProcessInfo.processInfo.physicalMemory }

    /// Bytes of swap currently in use (`vm.swapusage`); 0 if unavailable.
    /// High swap = the system is already under memory pressure.
    static func swapUsed() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    /// Rough peak resident footprint a loaded variant needs (weights + working
    /// set + compile scratch). Deliberately conservative — better to warn a touch
    /// early than to crash the model compiler.
    static func estimatedFootprint(_ model: WhisperModel) -> UInt64 {
        let mb: UInt64
        switch model {
        case .small:  mb = 1_200   // ~0.5 GB weights + overhead
        case .turbo:  mb = 1_600
        case .medium: mb = 3_000
        case .large:  mb = 6_000   // ~3 GB weights, ~6 GB resident at peak compile
        }
        return mb * 1_024 * 1_024
    }

    /// Swap level (bytes) at/above which we consider the system too pressured to
    /// safely compile a model. 4 GB of swap on Apple silicon indicates sustained
    /// pressure, the regime that previously corrupted the compiled-model cache.
    private static let swapPressureThreshold: UInt64 = 4 * 1_024 * 1_024 * 1_024

    /// A human-readable advisory if loading `model` looks risky on this machine,
    /// or `nil` if it's clear to load. Two distinct conditions:
    ///   1. the model is large relative to this Mac's RAM, and
    ///   2. the system is already thrashing swap right now.
    static func advisory(for model: WhisperModel) -> String? {
        let ram = physicalRAM
        let need = estimatedFootprint(model)
        let swap = swapUsed()

        // 1) Model too big for this Mac (leave ~40% headroom for the OS + apps).
        if need > ram * 6 / 10 {
            return "\(model.label) needs about \(gb(need)) of memory, but this Mac has \(gb(ram)). "
                 + "Loading it may thrash swap and can crash the model compiler — Turbo gives near-large accuracy at a fraction of the memory."
        }
        // 2) System already under heavy memory pressure — compiling a model now
        //    is what corrupted the model cache previously.
        if swap >= swapPressureThreshold {
            return "The system is low on memory (\(gb(swap)) of swap in use). "
                 + "Loading or recompiling a model now risks an interrupted compile. Quit memory-heavy apps or reboot first."
        }
        return nil
    }

    /// One-line memory snapshot for the log.
    static func snapshot() -> String {
        "physical RAM \(gb(physicalRAM)), swap in use \(gb(swapUsed()))"
    }

    static func gb(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }
}
