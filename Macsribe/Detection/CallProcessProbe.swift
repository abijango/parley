import Foundation
import CoreAudio

/// One process currently capturing microphone input.
struct AudioInputProcess: Equatable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
}

/// Thin Core Audio wrapper around the macOS 14.2+ process-object API. Validated
/// on-device: `kAudioProcessPropertyIsRunningInput` flips per process when it
/// captures the mic, and `DeviceIsRunningSomewhere` is the top-level gate.
/// All functions are nonisolated and cheap enough to poll.
enum CallProcessProbe {

    /// Is *anyone* capturing from the default input device right now?
    static func defaultInputRunningSomewhere() -> Bool {
        guard let device = defaultInputDevice() else { return false }
        return uint32(device, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1
    }

    /// Every process currently capturing input (`IsRunningInput == 1`).
    static func processesCapturingInput() -> [AudioInputProcess] {
        processObjectList().compactMap { obj in
            guard uint32(obj, kAudioProcessPropertyIsRunningInput) == 1 else { return nil }
            return AudioInputProcess(objectID: obj, pid: pid(obj) ?? -1, bundleID: bundleID(obj))
        }
    }

    /// Full snapshot (for verbose logging / the Detection status readout):
    /// every process object with its pid, bundle id, and input-running flag.
    static func snapshot() -> [(pid: pid_t, bundleID: String?, runningInput: Bool)] {
        processObjectList().map { obj in
            (pid(obj) ?? -1, bundleID(obj), uint32(obj, kAudioProcessPropertyIsRunningInput) == 1)
        }
    }

    // MARK: Core Audio plumbing

    static func defaultInputDevice() -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        return status == noErr ? device : nil
    }

    static func processObjectList() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func uint32(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func pid(_ obj: AudioObjectID) -> pid_t? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func bundleID(_ obj: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cf: CFString? = nil
        let status = withUnsafeMutablePointer(to: &cf) {
            AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let cf, !(cf as String).isEmpty else { return nil }
        return cf as String
    }
}
