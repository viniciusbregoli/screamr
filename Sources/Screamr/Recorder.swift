import AVFoundation

/// Captures the chosen input as 16 kHz mono PCM16, the format Scribe handles natively.
final class Recorder {
    /// Defaults key holding the Core Audio UID of the mic picked in Settings; empty means the system default.
    static let inputKey = "inputDevice"

    // A fresh engine per take: switching the device on a used engine leaves its input format stale,
    // and installing the tap then throws.
    private var engine = AVAudioEngine()
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private var pcm = Data()
    private let lock = NSLock()
    private var _level: Float = 0

    /// Loudness of the latest buffer, 0 (below -50 dB) to 1 (-10 dB and up), for the flow bar.
    var level: Float { lock.withLock { _level } }

    /// With `url`, audio streams to an AAC file on disk (long meetings) instead of memory.
    private var file: AVAudioFile?

    func start(writingTo url: URL? = nil) throws {
        lock.withLock { pcm.removeAll(keepingCapacity: true) }
        file = try url.map { try AVAudioFile(forWriting: $0, settings: Self.aac(sampleRate: 16_000), commonFormat: .pcmFormatInt16, interleaved: true) }
        engine = AVAudioEngine()
        let input = engine.inputNode
        selectInput(input)
        let source = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: source, to: target) else {
            throw NSError(domain: "Screamr", code: 1, userInfo: [NSLocalizedDescriptionKey: "No converter for \(source)"])
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: source) { [weak self] buffer, _ in
            guard let self else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * self.target.sampleRate / source.sampleRate) + 1
            guard let out = AVAudioPCMBuffer(pcmFormat: self.target, frameCapacity: capacity) else { return }
            var fed = false
            converter.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            if let samples = out.int16ChannelData?[0], out.frameLength > 0 {
                var sum: Float = 0
                for i in 0..<Int(out.frameLength) { let s = Float(samples[i]) / 32768; sum += s * s }
                let db = 10 * log10(max(sum / Float(out.frameLength), 1e-10))
                self.lock.withLock { self._level = min(1, max(0, (db + 50) / 40)) }
            }
            if let file = self.file {
                try? file.write(from: out)
                return
            }
            let bytes = Int(out.frameLength) * 2
            guard bytes > 0, let ptr = out.int16ChannelData?[0] else { return }
            self.lock.withLock { self.pcm.append(Data(bytes: ptr, count: bytes)) }
        }
        engine.prepare()
        try engine.start()
    }

    /// Stops capture and returns the take as a WAV file, plus its duration in seconds.
    func stop() -> (wav: Data, seconds: Double) {
        lock.withLock { _level = 0 }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil // closing the AVAudioFile finalizes the m4a
        let samples = lock.withLock { pcm }
        return (Self.wav(samples, sampleRate: 16_000), Double(samples.count) / 2 / 16_000)
    }

    /// Points a fresh engine at the chosen mic. With none chosen, or the chosen one unplugged,
    /// the engine keeps the system default.
    private func selectInput(_ input: AVAudioInputNode) {
        guard let uid = UserDefaults.standard.string(forKey: Self.inputKey), !uid.isEmpty, let unit = input.audioUnit else { return }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var cfUID = uid as CFString
        _ = withUnsafePointer(to: &cfUID) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        guard device != kAudioObjectUnknown else { return }
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, size)
    }

    /// Mics the user can pick, as (Core Audio UID, name).
    static func inputs() -> [(id: String, name: String)] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { ($0.uniqueID, $0.localizedName) }
    }

    static func aac(sampleRate: Double) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1]
    }

    static func wav(_ pcm: Data, sampleRate: UInt32) -> Data {
        var d = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + pcm.count))
        d.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(sampleRate); put(sampleRate * 2); put(UInt16(2)); put(UInt16(16))
        d.append(contentsOf: Array("data".utf8)); put(UInt32(pcm.count))
        d.append(pcm)
        return d
    }
}
