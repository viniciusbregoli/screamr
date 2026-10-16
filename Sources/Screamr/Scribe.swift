import Foundation

/// ElevenLabs Scribe batch transcription (POST /v1/speech-to-text).
enum Scribe {
    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func transcribe(wav: Data, apiKey: String, keyterms: [String] = []) async throws -> String {
        let boundary = UUID().uuidString
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model_id", "scribe_v2")
        // Drops fillers and false starts, which is most of what Wispr's cleanup pass does.
        field("no_verbatim", "true")
        field("tag_audio_events", "false")
        for term in keyterms { field("keyterms", term) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"take.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30

        let (data, resp) = try await URLSession.shared.upload(for: req, from: body)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw APIError(message: "Scribe HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        struct Response: Decodable { let text: String }
        return try JSONDecoder().decode(Response.self, from: data).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
