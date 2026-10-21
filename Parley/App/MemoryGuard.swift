import Foundation

/// System-memory inspection for logging during model load.
enum MemoryGuard {
    /// Total physical RAM on this Mac.
    static var physicalRAM: UInt64 { ProcessInfo.processInfo.physicalMemory }

    /// Bytes of swap currently in use (`vm.swapusage`); 0 if unavailable.
    static func swapUsed() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    /// One-line memory snapshot for the log.
    static func snapshot() -> String {
        "physical RAM \(gb(physicalRAM)), swap in use \(gb(swapUsed()))"
    }

    static func gb(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }
}
