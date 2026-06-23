import Foundation
import Combine

/// 智能 STT 引擎: 多個 implementation 之間 fallback
/// (v0.7.8+) Chain: Apple on-device → Apple cloud (proxy mode 取消, 唔再 fallback backend Whisper)
@MainActor
final class FallbackSpeechRecognizer: SpeechRecognizing, ObservableObject {

    let displayName = "Smart Fallback (推薦)"

    @Published var lastUsedEngine: String = ""
    @Published var lastFallbackReason: String = ""

    private let recognizers: [(name: String, recognizer: SpeechRecognizing)]

    init(recognizers: [(String, SpeechRecognizing)]) {
        self.recognizers = recognizers
    }

    // (v0.7.8+) defaultChain removed — proxy mode 取消, caller 用 hardcoded chain

    func isAvailable(language: String) -> Bool {
        recognizers.contains { $0.recognizer.isAvailable(language: language) }
    }

    func requestPermission() async -> Bool {
        // 第一個係 on-device Apple, request 一次
        return await recognizers.first?.recognizer.requestPermission() ?? false
    }

    func transcribe(audioURL: URL, language: String) async throws -> String {
        var lastError: Error?
        for (name, recognizer) in recognizers {
            guard recognizer.isAvailable(language: language) else { continue }
            do {
                let text = try await recognizer.transcribe(audioURL: audioURL, language: language)
                lastUsedEngine = name
                lastFallbackReason = ""
                return text
            } catch {
                lastError = error
                lastFallbackReason = "\(name) failed: \(error.localizedDescription)"
                print("[STT] \(lastFallbackReason), trying next…")
                continue
            }
        }
        // 全部 fallback 失敗
        throw lastError ?? SpeechRecognizerError.recognitionFailed("No STT engine succeeded")
    }
}

/// 用戶 explicit 揀邊個引擎 (Settings)
@MainActor
final class ChosenSpeechRecognizer: SpeechRecognizing, ObservableObject {
    let displayName: String
    let recognizer: SpeechRecognizing

    init(label: String, recognizer: SpeechRecognizing) {
        self.displayName = label
        self.recognizer = recognizer
    }

    func isAvailable(language: String) -> Bool { recognizer.isAvailable(language: language) }
    func requestPermission() async -> Bool { await recognizer.requestPermission() }
    func transcribe(audioURL: URL, language: String) async throws -> String {
        try await recognizer.transcribe(audioURL: audioURL, language: language)
    }
}
