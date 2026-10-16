import Foundation

/// ElevenLabs Scribe batch transcription (POST /v1/speech-to-text).
enum Scribe {
    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Response: Decodable {
        let text: String
        let words: [Transcript.Word]?
        let language_code: String?
    }

    /// Scribe takes one language or detects among ~99; the user speaks only English and Portuguese, mixed.
    static let languages: Set = ["eng", "por"]
    /// Portuguese tends to be misheard as one of these, especially in short takes.
    private static let nearPortuguese: Set = ["spa", "glg", "cat", "ita", "fra", "ron"]

    static func transcribe(wav: Data, apiKey: String, keyterms: [String] = []) async throws -> String {
        let fields = keyterms.map { ("keyterms", $0) }
        let r = try await request(audio: wav, filename: "take.wav", mime: "audio/wav", fields: fields, apiKey: apiKey, timeout: 30)
        return r.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Diarized, word-timestamped transcription of a recorded meeting channel.
    static func words(file: URL, apiKey: String, keyterms: [String] = []) async throws -> [Transcript.Word] {
        let audio = try Data(contentsOf: file)
        let fields = [("diarize", "true"), ("timestamps_granularity", "word")] + keyterms.map { ("keyterms", $0) }
        // ponytail: one synchronous request per channel; long meetings may need Scribe's webhook mode.
        let r = try await request(audio: audio, filename: file.lastPathComponent, mime: "audio/mp4", fields: fields, apiKey: apiKey, timeout: 900)
        return r.words ?? []
    }

    /// Auto-detects so mixed English/Portuguese speech stays intact; if detection lands on another
    /// language, transcribes again forced to the closer of the two.
    // ponytail: the retry bills the audio twice; it only fires on a misdetection.
    private static func request(audio: Data, filename: String, mime: String, fields: [(String, String)], apiKey: String, timeout: TimeInterval) async throws -> Response {
        let r = try await send(audio: audio, filename: filename, mime: mime, fields: fields, apiKey: apiKey, timeout: timeout)
        guard !r.text.isEmpty, let forced = fallbackLanguage(detected: r.language_code) else { return r }
        return try await send(audio: audio, filename: filename, mime: mime, fields: fields + [("language_code", forced)], apiKey: apiKey, timeout: timeout)
    }

    static func fallbackLanguage(detected: String?) -> String? {
        guard let detected, !languages.contains(detected) else { return nil }
        return nearPortuguese.contains(detected) ? "por" : "eng"
    }

    private static func send(audio: Data, filename: String, mime: String, fields: [(String, String)], apiKey: String, timeout: TimeInterval) async throws -> Response {
        let boundary = UUID().uuidString
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model_id", "scribe_v2")
        // Drops fillers and false starts, which is most of what Wispr's cleanup pass does.
        field("no_verbatim", "true")
        field("tag_audio_events", "false")
        for (name, value) in fields { field(name, value) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout

        let (data, resp) = try await URLSession.shared.upload(for: req, from: body)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw APIError(message: "Scribe HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
