import Foundation

/// 用戶友善嘅 STT error message — 包含 step-by-step 修復指引
enum STTErrorMessage {

    static func message(for error: SpeechRecognizerError) -> String {
        switch error {
        case .permissionDenied:
            return """
            STT 失敗: 冇 Speech Recognition 權限。
            修復: Settings → Apps → CantoneseVoiceChat → Speech Recognition → 開
            """
        case .onDeviceNotSupported:
            return """
            STT 失敗: on-device 粵語 model 載入唔到。
            修復: Settings → General → Keyboard → Dictation → 開「粵語 (香港)」, iOS 會下載 ~50MB on-device model (要 internet 一次)。
            下載完再返 app 撳 mic 重試。
            """
        case .languageNotSupported(let lang):
            return "STT 失敗: 語言 \(lang) 唔被呢部機嘅 STT 支援。"
        case .recognitionFailed(let msg):
            // 將 raw error 變成 user-friendly
            if msg.contains("timeout") {
                return "STT 失敗: 60s timeout. On-device model 可能未下載完, 或者錄音太長。試短啲錄。"
            }
            if msg.contains("0") && msg.contains(":") {
                return "STT 失敗: Apple Speech 報錯 \(msg)。可能 on-device 粵語 model 壞咗。去 Settings → General → Keyboard → Dictation → 刪除「粵語」再重新開。"
            }
            return "STT 失敗: \(msg)\n用 text input 試下, 或者去 Settings 改 STT engine."
        case .noResult:
            return "STT 失敗: 冇認到任何語音。試對住 mic 大聲啲講, 或者用 text input。"
        case .networkUnavailable:
            return "STT 失敗: 冇 network, 又冇 backend。"
        case .backendError(let code, let msg):
            return "Backend STT 失敗: HTTP \(code) \(msg)"
        }
    }
}
