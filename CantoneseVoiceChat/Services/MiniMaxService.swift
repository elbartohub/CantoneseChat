import Foundation

/// MiniMax API client — 支援兩種 mode:
/// 1. **Proxy mode** (預設, 原本個 stack): iPhone → Mac backend → MiniMax cloud
///    優點: API key 唔入 app, 可加 rate limiting / 用量追蹤
/// 2. **Direct mode** (新): iPhone → MiniMax cloud 直接
///    優點: 唔需要 Mac 行 backend, 改 settings 1 個 toggle 即用
///    缺點: API key 入 iOS UserDefaults, 任何 reverse engineer 拎到
///
/// Direct mode 設計畀 POC / 個人 demo 用, production 應該用 proxy mode
final class MiniMaxService {

    enum Mode: String {
        case proxy
        case direct
    }

    /// Mode (default: .proxy)
    var mode: Mode = .proxy

    /// Backend proxy URL (proxy mode)
    var baseURL: URL = URL(string: "http://localhost:8080")!

    /// MiniMax Cloud base URLs (direct mode)
    var llmBaseURL: URL = URL(string: "https://api.minimax.io")!
    var ttsBaseURL: URL = URL(string: "https://api-uw.minimax.io")!

    /// MiniMax API key (direct mode 必填; proxy mode 由 backend 持有)
    var apiKey: String = ""

    /// Optional: 用戶認證 token (proxy mode 用, direct mode 忽略)
    var authToken: String = ""

    /// STT 喺 direct mode: 唔用 backend Whisper, 改用 iOS on-device
    /// 喺 proxy mode: 用 backend /v1/audio/transcriptions

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 120
            config.waitsForConnectivity = true
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Request building

    private func makeProxyRequest(path: String, method: String = "POST") -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !authToken.isEmpty {
            req.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func makeDirectRequest(
        base: URL,
        path: String,
        method: String = "POST"
    ) -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    // MARK: - STT
    /// Transcribe 粵語錄音
    /// - proxy mode: 上傳去 Mac backend `/v1/audio/transcriptions`
    /// - direct mode: throw `.notSupported` (應該用 iOS native Apple STT, 唔好 call 呢個)
    func transcribe(audioURL: URL) async throws -> String {
        switch mode {
        case .proxy:
            return try await transcribeViaProxy(audioURL: audioURL)
        case .direct:
            throw MiniMaxError.notSupported("Direct mode 唔支援 STT, 改用 iOS on-device STT 喺 Settings 揀 🍎")
        }
    }

    private func transcribeViaProxy(audioURL: URL) async throws -> String {
        let url = baseURL.appendingPathComponent("/v1/audio/transcriptions")
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !authToken.isEmpty {
            req.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 30

        let fileData = try Data(contentsOf: audioURL)
        var body = Data()
        // file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        // model
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n".data(using: .utf8)!)
        // language
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\nyue\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, response) = try await session.data(for: req)
        try Self.assertOK(response: response, data: data)
        struct R: Decodable { let text: String }
        let decoded = try JSONDecoder().decode(R.self, from: data)
        return decoded.text
    }

    // MARK: - LLM
    struct ChatMessage: Codable {
        let role: String
        let content: String
    }

    /// Chat (non-streaming)
    func chat(messages: [ChatMessage]) async throws -> String {
        switch mode {
        case .proxy:
            return try await chatViaProxy(messages: messages)
        case .direct:
            return try await chatDirect(messages: messages)
        }
    }

    private func chatViaProxy(messages: [ChatMessage]) async throws -> String {
        var req = makeProxyRequest(path: "/v1/text/chatcompletion_v2")
        let payload: [String: Any] = [
            "model": "MiniMax-M3",
            "messages": messages.map { ["role": $0.role, "content": $0.content] as [String: String] },
            "stream": false,
            "temperature": 0.7,
            "top_p": 0.9,
            "max_tokens": 200
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: req)
        try Self.assertOK(response: response, data: data)
        return try Self.parseChatReply(data: data)
    }

    private func chatDirect(messages: [ChatMessage]) async throws -> String {
        var req = makeDirectRequest(base: llmBaseURL, path: "/v1/text/chatcompletion_v2")
        let payload: [String: Any] = [
            "model": "MiniMax-M3",
            "messages": messages.map { ["role": $0.role, "content": $0.content] as [String: String] },
            "stream": false,
            "temperature": 0.7,
            "top_p": 0.9
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: req)
        try Self.assertOK(response: response, data: data)
        return try Self.parseChatReply(data: data)
    }

    /// Chat (streaming SSE)
    func chatStream(
        messages: [ChatMessage],
        onDelta: @escaping (String) -> Void
    ) async throws -> String {
        switch mode {
        case .proxy:
            return try await chatStreamViaProxy(messages: messages, onDelta: onDelta)
        case .direct:
            return try await chatStreamDirect(messages: messages, onDelta: onDelta)
        }
    }

    private func chatStreamViaProxy(
        messages: [ChatMessage],
        onDelta: @escaping (String) -> Void
    ) async throws -> String {
        var req = makeProxyRequest(path: "/v1/text/chatcompletion_v2")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let payload: [String: Any] = [
            "model": "MiniMax-M3",
            "messages": messages.map { ["role": $0.role, "content": $0.content] as [String: String] },
            "stream": true,
            "temperature": 0.7,
            "top_p": 0.9
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, response) = try await session.bytes(for: req)
        try Self.assertOK(response: response, data: nil)

        var full = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            if let data = payload.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let first = choices.first,
               let delta = first["delta"] as? [String: Any],
               let content = delta["content"] as? String {
                full += content
                onDelta(content)
            }
        }
        return full
    }

    private func chatStreamDirect(
        messages: [ChatMessage],
        onDelta: @escaping (String) -> Void
    ) async throws -> String {
        var req = makeDirectRequest(base: llmBaseURL, path: "/v1/text/chatcompletion_v2")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let payload: [String: Any] = [
            "model": "MiniMax-M3",
            "messages": messages.map { ["role": $0.role, "content": $0.content] as [String: String] },
            "stream": true,
            "temperature": 0.7,
            "top_p": 0.9
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, response) = try await session.bytes(for: req)
        try Self.assertOK(response: response, data: nil)

        var full = ""
        for try await line in bytes.lines {
            // 兼容 data: 前綴 (MiniMax cloud 可能冇)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("data:") {
                let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                if let data = payload.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let first = choices.first,
                   let delta = first["delta"] as? [String: Any],
                   let content = delta["content"] as? String {
                    full += content
                    onDelta(content)
                }
            } else if !trimmed.isEmpty,
                      let data = trimmed.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let first = choices.first,
                      let delta = first["delta"] as? [String: Any],
                      let content = delta["content"] as? String {
                // raw JSON line (no data: prefix)
                full += content
                onDelta(content)
            }
        }
        return full
    }

    // MARK: - TTS (streaming)
    /// 串流 TTS — 一邊收 hex MP3 chunk 一邊派出去播
    func synthesizeStreaming(
        text: String,
        voiceId: String,
        languageBoost: String = "Chinese,Yue",
        onChunk: @escaping (Data) -> Void
    ) async throws {
        let model = UserDefaults.standard.string(forKey: "ttsModel") ?? "speech-2.8-turbo"
        switch mode {
        case .proxy:
            try await synthesizeStreamingViaProxy(
                text: text, voiceId: voiceId, languageBoost: languageBoost,
                model: model, onChunk: onChunk
            )
        case .direct:
            try await synthesizeStreamingDirect(
                text: text, voiceId: voiceId, languageBoost: languageBoost,
                model: model, onChunk: onChunk
            )
        }
    }

    private func synthesizeStreamingViaProxy(
        text: String, voiceId: String, languageBoost: String, model: String,
        onChunk: @escaping (Data) -> Void
    ) async throws {
        var req = makeProxyRequest(path: "/v1/t2a_v2")
        req.timeoutInterval = 60
        let payload: [String: Any] = [
            "model": model,
            "text": text,
            "stream": true,
            "language_boost": languageBoost,
            "output_format": "hex",
            "voice_setting": [
                "voice_id": voiceId,
                "speed": UserDefaults.standard.double(forKey: "speechRate"),
                "vol": 1.0, "pitch": 0
            ],
            "audio_setting": [
                "sample_rate": 32000, "bitrate": 128000, "format": "mp3", "channel": 1
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (bytes, response) = try await session.bytes(for: req)
        try Self.assertOK(response: response, data: nil)
        try await parseTTSStream(bytes: bytes, onChunk: onChunk)
    }

    private func synthesizeStreamingDirect(
        text: String, voiceId: String, languageBoost: String, model: String,
        onChunk: @escaping (Data) -> Void
    ) async throws {
        var req = makeDirectRequest(base: ttsBaseURL, path: "/v1/t2a_v2")
        req.timeoutInterval = 60
        let payload: [String: Any] = [
            "model": model,
            "text": text,
            "stream": true,
            "language_boost": languageBoost,
            "output_format": "hex",
            "voice_setting": [
                "voice_id": voiceId,
                "speed": UserDefaults.standard.double(forKey: "speechRate"),
                "vol": 1.0, "pitch": 0
            ],
            "audio_setting": [
                "sample_rate": 32000, "bitrate": 128000, "format": "mp3", "channel": 1
            ]
        ]
        // Fix typo
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "text": text,
            "stream": true,
            "language_boost": languageBoost,
            "output_format": "hex",
            "voice_setting": [
                "voice_id": voiceId,
                "speed": UserDefaults.standard.double(forKey: "speechRate"),
                "vol": 1.0, "pitch": 0
            ],
            "audio_setting": [
                "sample_rate": 32000, "bitrate": 128000, "format": "mp3", "channel": 1
            ]
        ])

        let (bytes, response) = try await session.bytes(for: req)
        try Self.assertOK(response: response, data: nil)
        try await parseTTSStream(bytes: bytes, onChunk: onChunk)
    }

    private func parseTTSStream(
        bytes: URLSession.AsyncBytes,
        onChunk: @escaping (Data) -> Void
    ) async throws {
        var chunkCount = 0
        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // 兼容 data: 前綴
            let payloadStr: String
            if trimmed.hasPrefix("data:") {
                payloadStr = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            } else {
                payloadStr = trimmed
            }
            guard !payloadStr.isEmpty,
                  let data = payloadStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let dataObj = obj["data"] as? [String: Any]
            if let hex = dataObj?["audio"] as? String, !hex.isEmpty {
                chunkCount += 1
                if chunkCount % 10 == 0 {
                    print("[TTS] chunk #\(chunkCount) \(hex.count) hex chars")
                }
                onChunk(Data(hex: hex))
            }
            if let status = dataObj?["status"] as? Int, status == 2 {
                break
            }
        }
        if chunkCount == 0 {
            print("[TTS] WARNING: no chunks received! check upstream")
        }
    }

    /// 同步 TTS (重聽)
    func synthesize(text: String, voiceId: String, languageBoost: String = "Chinese,Yue") async throws -> Data {
        let model = UserDefaults.standard.string(forKey: "ttsModel") ?? "speech-2.8-turbo"
        var req: URLRequest
        switch mode {
        case .proxy:
            req = makeProxyRequest(path: "/v1/t2a_v2")
        case .direct:
            req = makeDirectRequest(base: ttsBaseURL, path: "/v1/t2a_v2")
        }
        req.timeoutInterval = 30
        let payload: [String: Any] = [
            "model": model,
            "text": text,
            "stream": false,
            "language_boost": languageBoost,
            "output_format": "hex",
            "voice_setting": [
                "voice_id": voiceId,
                "speed": UserDefaults.standard.double(forKey: "speechRate"),
                "vol": 1.0, "pitch": 0
            ],
            "audio_setting": [
                "sample_rate": 32000, "bitrate": 128000, "format": "mp3", "channel": 1
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: req)
        try Self.assertOK(response: response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let hex = dataObj["audio"] as? String else {
            throw MiniMaxError.badResponse("TTS response missing data.audio")
        }
        return Data(hex: hex)
    }

    // MARK: - helpers
    private static func assertOK(response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw MiniMaxError.badResponse("Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw MiniMaxError.http(http.statusCode, snippet)
        }
    }

    private static func parseChatReply(data: Data) throws -> String {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw MiniMaxError.badResponse("chat reply not JSON: \(error.localizedDescription)")
        }
        guard let dict = json as? [String: Any] else {
            throw MiniMaxError.badResponse("chat reply not a JSON object")
        }
        if let choices = dict["choices"] as? [[String: Any]],
           let first = choices.first,
           let msg = first["message"] as? [String: Any],
           let content = msg["content"] as? String {
            return content
        }
        if let choices = dict["choices"] as? [[String: Any]],
           let first = choices.first,
           let text = first["text"] as? String {
            return text
        }
        throw MiniMaxError.badResponse("chat reply missing content")
    }
}

// MARK: - Errors
enum MiniMaxError: LocalizedError {
    case http(Int, String)
    case badResponse(String)
    case notSupported(String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let body):
            return "HTTP \(code): \(body.prefix(200))"
        case .badResponse(let msg):
            return msg
        case .notSupported(let msg):
            return msg
        }
    }
}

// MARK: - hex
extension Data {
    init(hex: String) {
        var data = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if hex.distance(from: idx, to: next) < 2 { break }
            if let byte = UInt8(hex[idx..<next], radix: 16) {
                data.append(byte)
            }
            idx = next
        }
        self = data
    }
}
