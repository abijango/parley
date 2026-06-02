import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import OSLog

/// Selects what non-microphone audio to capture.
enum SystemCaptureTarget {
    /// Everything you hear, minus our own process.
    case global
    /// A single application, by process id.
    case app(pid: pid_t)
}

enum SystemAudioCaptureError: Error, LocalizedError {
    case osStatus(String, OSStatus)
    case noProcessObject(pid_t)
    case invalidTapFormat

    var errorDescription: String? {
        switch self {
        case .osStatus(let op, let status):
            return "\(op) failed (OSStatus \(status))"
        case .noProcessObject(let pid):
            return "Could not resolve audio process object for pid \(pid)"
        case .invalidTapFormat:
            return "Could not read the tap's audio format"
        }
    }
}

/// Captures system / per-app output audio via Core Audio process taps
/// (macOS 14.4+) → the "Remote" track. Avoids ScreenCaptureKit (and its Screen
/// Recording permission). The first tap creation triggers the
/// `NSAudioCaptureUsageDescription` prompt; there is no pre-check API.
final class SystemAudioCapture {
    private let ringBuffer: AudioRingBuffer
    private let archiveURL: URL?
    private let log = Logger(subsystem: AppInfo.name, category: "SystemAudioCapture")

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private var resampler: AudioResampler?
    private var archiver: AudioArchiver?
    private let ioQueue = DispatchQueue(label: "\(AppInfo.name).systemAudioIO", qos: .userInitiated)
    private var isRunning = false

    let meter = LevelMeter()
    var level: Float { meter.level }

    init(ringBuffer: AudioRingBuffer, archiveURL: URL?) {
        self.ringBuffer = ringBuffer
        self.archiveURL = archiveURL
    }

    /// Surfaces the `NSAudioCaptureUsageDescription` TCC prompt early by briefly
    /// creating and destroying a global tap. There is no pre-request API, so
    /// this is the only way to get the prompt out of the way before recording.
    /// No-op (and silent) once permission is already granted. Run off the main
    /// thread — the call can block until the user answers the prompt.
    ///
    /// Returns `true` if the tap was created (audio capture is available), or
    /// `false` if it couldn't be — which, after the prompt has been answered,
    /// means the audio-recording permission was denied. Use it to surface a
    /// permission problem instead of failing silently at record time.
    @discardableResult
    static func primeAudioCapturePermission() -> Bool {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            AppLog.log("Audio-capture prime failed (OSStatus \(status)) — system-audio capture/detection may be blocked by the audio-recording permission", category: "audio")
            return false
        }
        AudioHardwareDestroyProcessTap(tapID)
        return true
    }

    // MARK: Crash cleanup

    /// Best-effort launch sweep: destroy any aggregate device this app left
    /// behind after a crash. A leaked aggregate persists system-wide (it shows
    /// up in Audio MIDI Setup and can even become the default device), so a
    /// hard crash mid-recording — without `stop()`/`teardown()` running — would
    /// otherwise litter the system. Matched by the app-stamped device name.
    /// Safe to call once at launch before any recording starts.
    static func cleanupLeakedAggregates() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var devices = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &devices) == noErr else { return }

        let wantedName = "\(AppInfo.name) Aggregate"   // TODO(app-name)
        var cleaned = 0
        for device in devices where device != kAudioObjectUnknown {
            guard transportType(of: device) == kAudioDeviceTransportTypeAggregate,
                  deviceName(of: device) == wantedName else { continue }
            let status = AudioHardwareDestroyAggregateDevice(device)
            cleaned += 1
            AppLog.log("Cleaned up leaked aggregate device '\(wantedName)' (id \(device), status \(status)) — likely from a previous crash", category: "audio")
        }
        if cleaned == 0 {
            AppLog.log("Aggregate-device cleanup: none leaked", category: "audio")
        }
    }

    private static func transportType(of device: AudioObjectID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private static func deviceName(of device: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var name: CFString? = nil
        let status = withUnsafeMutablePointer(to: &name) { ptr -> OSStatus in
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let name else { return nil }
        return name as String
    }

    // MARK: Lifecycle

    func start(target: SystemCaptureTarget) throws {
        guard !isRunning else { return }
        do {
            try createTap(for: target)
            try createAggregateDevice()
            try readTapFormat()
            try installIOProc()
            try checkStatus(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")
            isRunning = true
        } catch {
            teardown()   // never leak an aggregate device / tap on a failed start
            throw error
        }
    }

    func stop() {
        guard isRunning else { return }
        teardown()
        isRunning = false
    }

    // MARK: Tap creation

    private func createTap(for target: SystemCaptureTarget) throws {
        let description: CATapDescription
        switch target {
        case .global:
            // Exclude ourselves so we never capture our own output.
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        case .app(let pid):
            guard let processObject = Self.audioProcessObject(for: pid) else {
                throw SystemAudioCaptureError.noProcessObject(pid)
            }
            description = CATapDescription(stereoMixdownOfProcesses: [processObject])
        }
        description.uuid = UUID()
        description.muteBehavior = .unmuted   // observe without silencing playback
        description.isPrivate = true
        description.name = "\(AppInfo.name) Tap"   // TODO(app-name)

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        try checkStatus(AudioHardwareCreateProcessTap(description, &newTapID), "AudioHardwareCreateProcessTap")
        tapID = newTapID
    }

    /// Translate a process id into the Core Audio process AudioObjectID.
    private static func audioProcessObject(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidValue = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pidValue,
            &size,
            &objectID
        )
        return status == noErr ? objectID : nil
    }

    // MARK: Aggregate device

    private func createAggregateDevice() throws {
        guard let tapUUID = tapUUIDString() else {
            throw SystemAudioCaptureError.osStatus("read tap UUID", -1)
        }
        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "\(AppInfo.name) Aggregate",   // TODO(app-name)
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[String: Any]](),
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID,
                ]
            ],
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        try checkStatus(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID),
            "AudioHardwareCreateAggregateDevice"
        )
        aggregateID = newAggregateID
    }

    private func tapUUIDString() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var uid: CFString? = nil
        let status = withUnsafeMutablePointer(to: &uid) { ptr -> OSStatus in
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let uid else { return nil }
        return uid as String
    }

    // MARK: Tap format

    private func readTapFormat() throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try checkStatus(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd),
            "read kAudioTapPropertyFormat"
        )
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw SystemAudioCaptureError.invalidTapFormat
        }
        tapFormat = format
        resampler = AudioResampler(inputFormat: format)
        if let archiveURL {
            archiver = try? AudioArchiver(url: archiveURL, format: format)
        }
    }

    // MARK: IO proc

    private func installIOProc() throws {
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) {
            [weak self] _, inInputData, _, _, _ in
            self?.handleInput(inInputData)
        }
        try checkStatus(status, "AudioDeviceCreateIOProcIDWithBlock")
        ioProcID = procID
    }

    /// Invoked on `ioQueue` with the tap's audio. Wrap (no copy), archive,
    /// resample to 16 kHz mono, push into the ring buffer.
    private func handleInput(_ bufferList: UnsafePointer<AudioBufferList>) {
        guard let format = tapFormat else { return }
        guard let pcm = AVAudioPCMBuffer(
            pcmFormat: format,
            bufferListNoCopy: bufferList,
            deallocator: nil
        ) else { return }

        archiver?.append(pcm)
        if let floats = resampler?.resample(pcm), !floats.isEmpty {
            floats.withUnsafeBufferPointer { ringBuffer.write($0) }
            meter.update(floats)
        }
    }

    // MARK: Teardown

    private func teardown() {
        if let ioProcID {
            if aggregateID != kAudioObjectUnknown {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        if let archiver {
            AppLog.log("System archive: \(archiver.framesWritten) frames written", category: "audio")
        }
        archiver = nil
        resampler = nil
        tapFormat = nil
    }

    private func checkStatus(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            log.error("\(operation, privacy: .public) failed: \(status)")
            AppLog.log("System audio: \(operation) failed (OSStatus \(status))", category: "audio")
            throw SystemAudioCaptureError.osStatus(operation, status)
        }
    }
}
