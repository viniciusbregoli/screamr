import AVFoundation
import CoreAudio

/// Records everything the Mac plays (the other side of a call) through a Core Audio process tap,
/// the same mechanism Chromium uses for Wispr's notetaker. Needs macOS 14.4+ and the
/// "System Audio Recording" permission (prompted on first start).
final class SystemAudioTap {
    struct Failure: LocalizedError {
        let step: String, status: OSStatus
        var errorDescription: String? { "System audio \(step) failed (\(status))" }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: "screamr.system-audio")
    /// Loudest sample seen, so a meeting with no call audio can skip transcribing a silent file.
    private(set) var peak: Float = 0

    func start(writingTo url: URL) throws {
        peak = 0
        let desc = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.isPrivate = true
        try check("tap", AudioHardwareCreateProcessTap(desc, &tapID))

        var asbd = AudioStreamBasicDescription()
        try get(tapID, kAudioTapPropertyFormat, &asbd, "tap format")
        guard let format = AVAudioFormat(streamDescription: &asbd) else { throw Failure(step: "format", status: -1) }

        let outputUID = try defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Screamr System Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        try check("aggregate device", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))

        let file = try AVAudioFile(forWriting: url, settings: Recorder.aac(sampleRate: format.sampleRate),
                                   commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        self.file = file
        try check("io proc", AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            guard let self, let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            if let samples = buffer.floatChannelData?[0] {
                for i in 0..<Int(buffer.frameLength) { self.peak = max(self.peak, abs(samples[i])) }
            }
            try? self.file?.write(from: buffer)
        })
        try check("start", AudioDeviceStart(aggregateID, procID))
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        queue.sync { file = nil } // closing finalizes the m4a; sync so no write is mid-flight
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        try get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, &device, "output device")
        var uid: Unmanaged<CFString>?
        try get(device, kAudioDevicePropertyDeviceUID, &uid, "output uid")
        guard let uid else { throw Failure(step: "output uid", status: -1) }
        return uid.takeRetainedValue() as String
    }

    private func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T, _ step: String) throws {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        try check(step, AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value))
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else { throw Failure(step: step, status: status) }
    }
}
