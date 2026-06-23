import Foundation
import AVFoundation
import Speech

/// STT 引擎抽象: 支援 3 個 implementation
/// - Apple on-device SFSpeechRecognizer (預設, 100% offline, 粵語支援需要 iOS 17+)
/// - Apple cloud SFSpeechRecognizer (fallback, 需要 internet + Apple ID)
/// - Backend Whisper (透過 Mac/Linux backend, 質量高, 需網絡)
@MainActor
protocol SpeechRecognizing: AnyObject {
    /// 引擎 display name
    var displayName: String { get }

    /// 是否可以即時用 (on-device model 下咗、未在用緊 mic 等等)
    func isAvailable(language: String) -> Bool

    /// 請求權限 (mic + speech recognition)
    func requestPermission() async -> Bool

    /// Transcribe 一段音訊 file
    /// - Parameters:
    ///   - audioURL: m4a/aac/wav file URL
    ///   - language: BCP-47 code, e.g. "yue" / "zh-HK" / "en-US"
    func transcribe(audioURL: URL, language: String) async throws -> String
}

enum SpeechRecognizerError: LocalizedError {
    case permissionDenied
    case onDeviceNotSupported
    case languageNotSupported(String)
    case recognitionFailed(String)
    case noResult
    case networkUnavailable
    case backendError(Int, String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "冇 STT 權限, 請去 Settings 開"
        case .onDeviceNotSupported:
            return "呢部機嘅 on-device STT model 載入唔到或唔支援"
        case .languageNotSupported(let lang):
            return "語言 \(lang) 唔被呢個 STT 引擎支援"
        case .recognitionFailed(let msg):
            return "STT 失敗: \(msg)"
        case .noResult:
            return "STT 冇任何 result"
        case .networkUnavailable:
            return "冇 internet, 又冇 backend"
        case .backendError(let code, let msg):
            return "Backend STT 失敗: HTTP \(code) \(msg)"
        }
    }
}

/// 將 "yue" / "zh-HK" / "zh-CN" / "en-US" 統一做 SFSpeechRecognizer 嘅 BCP-47
enum SpeechLanguage {
    /// 對 Apple SFSpeechRecognizer 嚟講, 用 BCP-47 (zh-HK)
    static func apple(_ code: String) -> String {
        switch code.lowercased() {
        case "yue", "zh-yue", "cantonese", "粵語", "廣東話":
            return "zh-HK"
        case "zh", "zh-cn", "chinese":
            return "zh-CN"
        case "en":
            return "en-US"
        default:
            return code
        }
    }

    /// Backend Whisper 用 ISO 639-1 (yue, zh, en)
    static func whisper(_ code: String) -> String {
        switch code.lowercased() {
        case "zh-hk", "zh-yue", "cantonese", "粵語", "廣東話":
            return "yue"
        case "zh", "zh-cn", "chinese":
            return "zh"
        case "en", "en-us":
            return "en"
        default:
            return code
        }
    }
}
