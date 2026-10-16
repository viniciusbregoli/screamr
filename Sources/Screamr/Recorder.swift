import AVFoundation

/// Captures the default input as 16 kHz mono PCM16, the format Scribe handles natively.
final class Recorder {
    private let engine = AVAudioEngine()
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private var pcm = Data()
    private let lock = NSLock()

    func start() throws {
        lock.withLock { pcm.removeAll(keepingCapacity: true) }
        let input = engine.inputNode
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
            let bytes = Int(out.frameLength) * 2
            guard bytes > 0, let ptr = out.int16ChannelData?[0] else { return }
            self.lock.withLock { self.pcm.append(Data(bytes: ptr, count: bytes)) }
        }
        engine.prepare()
        try engine.start()
    }

    /// Stops capture and returns the take as a WAV file, plus its duration in seconds.
    func stop() -> (wav: Data, seconds: Double) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let samples = lock.withLock { pcm }
        return (Self.wav(samples, sampleRate: 16_000), Double(samples.count) / 2 / 16_000)
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
