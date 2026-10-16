import AVFoundation
import FluidAudio

/// On-device voice fingerprints: 256-d WeSpeaker embeddings through FluidAudio's Core ML models
/// (downloaded once from Hugging Face on first use). Audio never leaves the Mac for this step.
actor VoicePrinter {
    static let shared = VoicePrinter()
    /// The embedding model sees 10 s windows; longer clips get truncated by FluidAudio.
    static let window = 10.0
    /// Less speech than this gives unreliable fingerprints, so such speakers are skipped.
    static let minSpeech = 3.0

    private var manager: DiarizerManager?

    private func loaded() async throws -> DiarizerManager {
        if let manager { return manager }
        let m = DiarizerManager()
        m.initialize(models: try await DiarizerModels.downloadIfNeeded())
        manager = m
        return m
    }

    /// Fingerprint of one speaker in a recording, from up to 30 s of their longest stretches of speech.
    func fingerprint(file: URL, segments: [(start: Double, end: Double)]) async throws -> [Float]? {
        let clips = Self.clips(samples: try Self.read(file, ranges: segments, upTo: 3 * Self.window))
        guard !clips.isEmpty else { return nil }
        let m = try await loaded()
        return Self.mean(try clips.map { try m.extractSpeakerEmbedding(from: $0) })
    }

    /// Splits pooled speech into model windows, dropping a tail too short to fingerprint.
    nonisolated static func clips(samples: [Float], rate: Double = 16_000) -> [[Float]] {
        let size = Int(window * rate)
        return stride(from: 0, to: samples.count, by: size)
            .map { Array(samples[$0..<min($0 + size, samples.count)]) }
            .filter { Double($0.count) >= minSpeech * rate }
    }

    nonisolated static func mean(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors { for i in sum.indices { sum[i] += v[i] } }
        let norm = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? sum.map { $0 / norm } : sum
    }

    /// Cosine distance between L2-normalized vectors: 0 is identical, 2 is opposite.
    nonisolated static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 2 }
        return 1 - zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    /// Decodes only the given time ranges (longest first, up to `upTo` seconds) as 16 kHz mono,
    /// so an hour-long meeting never has to be decoded whole.
    nonisolated static func read(_ url: URL, ranges: [(start: Double, end: Double)], upTo limit: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: source, to: target) else { return [] }
        var out: [Float] = []
        for r in ranges.sorted(by: { $0.end - $0.start > $1.end - $1.start }) {
            guard Double(out.count) / 16_000 < limit else { break }
            let first = AVAudioFramePosition(r.start * source.sampleRate)
            let frames = AVAudioFrameCount(max(0, min(Double(file.length - first), (r.end - r.start) * source.sampleRate)))
            guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames) else { continue }
            file.framePosition = first
            try file.read(into: input, frameCount: frames)
            let capacity = AVAudioFrameCount(Double(frames) * 16_000 / source.sampleRate) + 1024
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { continue }
            converter.reset()
            var fed = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if fed { status.pointee = .endOfStream; return nil }
                fed = true
                status.pointee = .haveData
                return input
            }
            if let error { throw error }
            if let data = output.floatChannelData?[0] { out.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(output.frameLength))) }
        }
        return out
    }
}
