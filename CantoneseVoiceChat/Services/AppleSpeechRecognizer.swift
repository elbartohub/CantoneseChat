import Foundation
import Speech
import AVFoundation

/// iOS native Speech framework 嘅 wrapper, 兩個 mode:
/// - on-device (100% offline, 私隱, 預設)
/// - cloud (Apple server, fallback, 需要 internet)
///
/// Cantonese on-device 需要 iOS 17.0+ AND 粵語 on-device model
@MainActor
final class AppleSpeechRecognizer: SpeechRecognizing {

    let displayName = "iOS On-device / Cloud (Apple)"

    /// on-device mode 強制唔 fallback 落 cloud
    let onDeviceOnly: Bool

    init(onDeviceOnly: Bool = true) {
        self.onDeviceOnly = onDeviceOnly
    }

    func isAvailable(language: String) -> Bool {
        let bcp = SpeechLanguage.apple(language)
        let locale = Locale(identifier: bcp)
        let recognizer = SFSpeechRecognizer(locale: locale)
        guard let recognizer, recognizer.isAvailable else { return false }
        if onDeviceOnly {
            return recognizer.supportsOnDeviceRecognition
        }
        return true
    }

    /// 診斷用: 列出呢部 device 嗰個語言嘅 STT 狀態 (debug log)
    func diagnose(language: String) -> String {
        let bcp = SpeechLanguage.apple(language)
        let locale = Locale(identifier: bcp)
        let status = SFSpeechRecognizer.authorizationStatus()
        let authText: String
        switch status {
        case .authorized: authText = "✅ authorized"
        case .denied: authText = "❌ denied (去 Settings → CantoneseVoiceChat → Speech Recognition)"
        case .restricted: authText = "❌ restricted (parental control 鎖咗)"
        case .notDetermined: authText = "⏳ not yet asked"
        @unknown default: authText = "❓ unknown"
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            return "[\(bcp)] \(authText), locale 不支援"
        }
        let avail = recognizer.isAvailable ? "✅ available" : "❌ not available"
        let onDev = recognizer.supportsOnDeviceRecognition ? "✅ on-device supported" : "❌ on-device NOT supported (要 Settings → General → Keyboard → Dictation → 開粵語)"
        return "[\(bcp)] \(authText), recognizer: \(avail), \(onDev)"
    }

    func requestPermission() async -> Bool {
        // 1) Speech recognition 權限
        let speechStatus: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        // 2) Mic 權限 (順便 request, fail 都唔 block STT — STT file 唔需要 mic)
        _ = await AVCaptureRequester.shared.requestMicrophone()
        return speechStatus == .authorized
    }

    func transcribe(audioURL: URL, language: String) async throws -> String {
        let bcp = SpeechLanguage.apple(language)
        let locale = Locale(identifier: bcp)

        // 0) 權限檢查
        let authStatus = SFSpeechRecognizer.authorizationStatus()
        if authStatus == .notDetermined {
            // 未問過, 即 request (會彈 iOS permission dialog)
            let granted = await requestPermission()
            if !granted {
                print("[STT] Speech recognition permission denied")
                throw SpeechRecognizerError.permissionDenied
            }
        } else if authStatus == .denied {
            print("[STT] Speech recognition permission denied, go to Settings")
            throw SpeechRecognizerError.permissionDenied
        } else if authStatus == .restricted {
            print("[STT] Speech recognition restricted by parental controls")
            throw SpeechRecognizerError.permissionDenied
        }

        // 1) Locale 檢查
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            print("[STT] no recognizer for locale \(bcp)")
            throw SpeechRecognizerError.languageNotSupported(bcp)
        }
        if !recognizer.isAvailable {
            print("[STT] recognizer not available for \(bcp)")
            throw SpeechRecognizerError.recognitionFailed("SFSpeechRecognizer unavailable, 可能要 Settings → General → Keyboard → Dictation 開 on-device 粵語")
        }
        // 詳細診斷 log
        print("[STT] locale=\(bcp) available=\(recognizer.isAvailable) onDeviceSupported=\(recognizer.supportsOnDeviceRecognition) onDeviceOnly=\(onDeviceOnly)")

        // 2) on-device 支援
        if onDeviceOnly && !recognizer.supportsOnDeviceRecognition {
            print("[STT] on-device NOT supported for \(bcp). User need to: Settings → General → Keyboard → Dictation → enable 粵語 (iOS 會下載 ~50MB on-device model)")
            throw SpeechRecognizerError.onDeviceNotSupported
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        if onDeviceOnly {
            request.requiresOnDeviceRecognition = true
        }
        request.shouldReportPartialResults = false
        // 粵語唔好用標點
        if bcp.hasPrefix("zh") || bcp.hasPrefix("yue") {
            request.addsPunctuation = false
        }
        if #available(iOS 16.0, *) {
            request.addsPunctuation = false
        }

        print("[STT] 開始 transcription: file=\(audioURL.lastPathComponent) size=\(try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] ?? 0) lang=\(bcp) onDevice=\(onDeviceOnly)")

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            var didResume = false
            // 設定 timeout 60 秒 (on-device 粵語 model 大)
            let timeoutWorkItem = DispatchWorkItem {
                if !didResume {
                    didResume = true
                    cont.resume(throwing: SpeechRecognizerError.recognitionFailed("STT timeout (60s), on-device model 可能未 download 完"))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: timeoutWorkItem)

            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if !didResume {
                        didResume = true
                        timeoutWorkItem.cancel()
                        // Map NSError 常見 code
                        let nsErr = error as NSError
                        let code = nsErr.code
                        let desc = nsErr.localizedDescription
                        print("[STT] error: code=\(code) domain=\(nsErr.domain) desc=\(desc)")
                        // kAFAssistantErrorDomain = 0, code 0..15 常見
                        cont.resume(throwing: SpeechRecognizerError.recognitionFailed("code \(code): \(desc)"))
                    }
                    return
                }
                guard let result else { return }
                if result.isFinal {
                    let text = result.bestTranscription.formattedString
                    if !didResume {
                        didResume = true
                        timeoutWorkItem.cancel()
                        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            cont.resume(throwing: SpeechRecognizerError.noResult)
                        } else {
                            print("[STT] ✅ ok: '\(text.prefix(60))'")
                            cont.resume(returning: text)
                        }
                    }
                }
            }
        }
    }
}

/// Mic 權限 helper — 封裝 AVCaptureDevice.requestAccess
@MainActor
final class AVCaptureRequester {
    static let shared = AVCaptureRequester()
    private init() {}
    func requestMicrophone() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }
}
