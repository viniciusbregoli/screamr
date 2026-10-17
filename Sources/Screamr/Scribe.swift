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

    static let model = "scribe_v2"

    /// Verbatim keeps fillers ("um", "é", "hum") and false starts; clean (`no_verbatim`) drops them.
    /// Dictation defaults to clean, since the text gets pasted; meetings default to verbatim, since
    /// they are the data for speech analysis and fillers are part of what gets measured.
    static let dictationVerbatimKey = "dictationVerbatim"
    static let meetingVerbatimKey = "meetingVerbatim"
    static var dictationVerbatim: Bool { UserDefaults.standard.object(forKey: dictationVerbatimKey) as? Bool ?? false }
    static var meetingVerbatim: Bool { UserDefaults.standard.object(forKey: meetingVerbatimKey) as? Bool ?? true }

    /// One transcribed meeting channel and the language Scribe settled on for it.
    struct Channel {
        let words: [Transcript.Word]
        let language: String?
    }

    /// How a meeting was transcribed, saved as meta.json next to its words so analysis can filter on it
    /// and never mixes verbatim and clean transcripts.
    struct Meta: Codable, Equatable {
        var transcription_mode: String
        var model_id: String
        /// "mac" or "iphone": on the Mac the mic channel is the user, on the iPhone everyone shares it.
        var source: String
        var transcribed_at: Date
        /// Channel ("mic", "system") to Scribe's language code, e.g. "por".
        var languages: [String: String]

        init(verbatim: Bool, languages: [String: String], at date: Date = Date()) {
            transcription_mode = verbatim ? "verbatim" : "clean"
            model_id = Scribe.model
            #if os(iOS)
            source = "iphone"
            #else
            source = "mac"
            #endif
            transcribed_at = date
            self.languages = languages
        }

        func write(to dir: URL) throws {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        }
    }

    /// Scribe takes one language or detects among ~99; the user speaks only English and Portuguese, mixed.
    static let languages: Set = ["eng", "por"]
    /// Portuguese tends to be misheard as one of these, especially in short takes.
    private static let nearPortuguese: Set = ["spa", "glg", "cat", "ita", "fra", "ron"]

    static func transcribe(wav: Data, apiKey: String, keyterms: [String] = [], verbatim: Bool = dictationVerbatim) async throws -> String {
        let fields = formFields(verbatim: verbatim) + keyterms.map { ("keyterms", $0) }
        let r = try await request(audio: wav, filename: "take.wav", mime: "audio/wav", fields: fields, apiKey: apiKey, timeout: 30)
        return r.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Diarized, word-timestamped transcription of a recorded meeting channel.
    static func words(file: URL, apiKey: String, keyterms: [String] = [], verbatim: Bool = meetingVerbatim) async throws -> Channel {
        let audio = try Data(contentsOf: file)
        let fields = formFields(verbatim: verbatim) + [("diarize", "true"), ("timestamps_granularity", "word")] + keyterms.map { ("keyterms", $0) }
        // ponytail: one synchronous request per channel; long meetings may need Scribe's webhook mode.
        let r = try await request(audio: audio, filename: file.lastPathComponent, mime: "audio/mp4", fields: fields, apiKey: apiKey, timeout: 900)
        return Channel(words: r.words ?? [], language: r.language_code)
    }

    static func formFields(verbatim: Bool) -> [(String, String)] {
        [("model_id", model), ("no_verbatim", verbatim ? "false" : "true"), ("tag_audio_events", "false")]
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
        guard let detected else { return nil }
        let code = iso639_3(detected)
        guard !languages.contains(code) else { return nil }
        return nearPortuguese.contains(code) ? "por" : "eng"
    }

    /// Scribe answers with three-letter codes ("por"), but its docs show two-letter ones ("en");
    /// accepting both keeps a code-format change from forcing every take through a second, billed request.
    static func iso639_3(_ code: String) -> String {
        let twoLetter = ["en": "eng", "pt": "por", "es": "spa", "gl": "glg", "ca": "cat", "it": "ita", "fr": "fra", "ro": "ron"]
        let base = code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? code.lowercased()
        return twoLetter[base] ?? base
    }

    private static func send(audio: Data, filename: String, mime: String, fields: [(String, String)], apiKey: String, timeout: TimeInterval) async throws -> Response {
        let boundary = UUID().uuidString
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
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
