import Foundation
import AVFoundation
import Combine

/// TTS-only 模式嘅 ViewModel — 用戶輸入文字，照讀出嚟
/// Cache-first: 同一 (persona.voiceId, trimmed text) pair 已經 cache 就直接由 disk 讀，唔再 call API
/// 唔需要 backend / chat history / persona system prompt — 純文字→TTS
@MainActor
final class TtsLabViewModel: ObservableObject {

    enum State: Equatable {
        case idle
        case synthesizing
        case playing
        case error(String)
        // (v0.7.9+) LLM 廣東話優化 operation
        case enhancing
    }

    enum CacheState: Equatable {
        case unknown       // text 未輸入
        case miss          // (voice, text) 對上一次 cache miss
        case hit           // (voice, text) 對應 lastPlayedCachePath 仍然在
    }

    /// v0.7.1: 語音輸入 state — 獨立於 TTS state
    enum SpeechState: Equatable {
        case idle
        case requestingPermission
        case listening
        case transcribing
        case error(String)
    }

    @Published var inputText: String = ""
    @Published var selectedPersona: Persona = .chaChaanTang
    @Published var state: State = .idle
    @Published var cacheState: CacheState = .unknown
    @Published var speechState: SpeechState = .idle

    /// 用戶最後一次播放嘅 cache 相對 path（nil = 冇 / 已清）
    /// 用嚟支援「再聽一次」button
    private(set) var lastPlayedCachePath: String?

    /// 對應 lastPlayedCachePath 嘅 (voiceId, trimmed text) 指紋
    /// 用嚟判斷「現在輸入嘅文字」係咪仲用緊同一段 cache
    private var lastPlayedFingerprint: String?

    private let service: MiniMaxService
    private var currentPlayer: AVAudioPlayer?
    private let audio: AudioRecording
    private let recognizer: SpeechRecognizing

    init(
        service: MiniMaxService? = nil,
        audio: AudioRecording? = nil,
        recognizer: SpeechRecognizing? = nil,
        icloudExporter: ICloudExportService? = nil
    ) {
        // (v0.7.8+) Proxy mode removed — direct mode only
        // iPhone 直接 hit MiniMax cloud (api.minimax.io)
        let svc = service ?? MiniMaxService()
        svc.mode = .direct
        svc.authToken = UserDefaults.standard.string(forKey: "apiKey") ?? ""
        svc.apiKey = UserDefaults.standard.string(forKey: "minimaxApiKey") ?? svc.authToken
        self.service = svc
        self.audio = audio ?? AudioService()
        // Default chain: iOS on-device zh-HK → backend Whisper fallback
        if let recognizer {
            self.recognizer = recognizer
        } else {
            self.recognizer = FallbackSpeechRecognizer(recognizers: [
                ("iOS On-device (zh-HK, 優先)", AppleSpeechRecognizer(onDeviceOnly: true)),
            ])
        }
        // Default 用 shared singleton (v0.7.4), 令 SettingsView 同 TtsLabView 共享同一 instance
        self.icloudExporter = icloudExporter ?? ICloudExportService.shared
    }

    // iCloud export (v0.7.3)
    let icloudExporter: ICloudExportService

    /// 將當前 inputText 嘅 TTS audio 寫入 user 嘅 iCloud folder
    /// - 已 bookmark 過嘅 folder → 立即寫入
    /// - 未 bookmark → return false (View layer 應該彈 document picker)
    /// - Returns: true 表示成功 trigger export, false 表示需要先 pick folder
    @discardableResult
    func exportLastAudioToICloud() async -> Bool {
        print("[TtsLab] exportLastAudioToICloud called")
        // (v0.7.5) Reset 之前嘅狀態, 確保 banner 即時更新 + 防止 stuck state
        icloudExporter.state = .exporting

        guard let path = lastPlayedCachePath,
              let url = TTSCache.absoluteURL(for: path) else {
            print("[TtsLab] export FAIL: 冇 lastPlayedCachePath / cache file 唔見咗")
            icloudExporter.state = .error("冇 TTS audio 可 export, 請先撳「讀出嚟」")
            return false
        }
        do {
            let data = try Data(contentsOf: url)
            let filename = generateExportFilename()
            if let savedFolder = icloudExporter.savedFolderURL() {
                print("[TtsLab] export: bookmark 有 folder \(savedFolder.lastPathComponent), 直接寫入")
                await icloudExporter.export(data: data, filename: filename)
                // (v0.7.5) Auto-clear success banner 1.5s 後, 咁 user 見到 feedback 但唔會 stuck
                let savedPath = icloudExporter.state
                if case .success = savedPath {
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        // 只 clear 仲係 success 嘅 (避免覆蓋後續 error)
                        if case .success = self?.icloudExporter.state {
                            self?.icloudExporter.state = .idle
                        }
                    }
                }
                return true
            } else {
                print("[TtsLab] export: 冇 saved folder, return false → View 應該彈 FolderPicker")
                icloudExporter.state = .idle  // reset exporting flag
                return false
            }
        } catch {
            print("[TtsLab] export FAIL: 讀 cache 失敗 \(error.localizedDescription)")
            icloudExporter.state = .error("讀 cache 失敗: \(error.localizedDescription)")
            return false
        }
    }

    /// Document picker 揀完 folder 後立即 export
    func handlePickedFolderAndExport(_ url: URL) {
        print("[TtsLab] handlePickedFolderAndExport: \(url.lastPathComponent) (path=\(url.path))")
        guard let path = lastPlayedCachePath,
              let fileURL = TTSCache.absoluteURL(for: path) else {
            print("[TtsLab] handlePicked FAIL: 冇 lastPlayedCachePath")
            icloudExporter.state = .error("冇 TTS audio 可 export, 請先撳「讀出嚟」")
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let filename = generateExportFilename()
            print("[TtsLab] handlePicked: invoke ICloudExportService.handlePickedFolder")
            icloudExporter.handlePickedFolder(url, data: data, filename: filename)
        } catch {
            print("[TtsLab] handlePicked FAIL: \(error.localizedDescription)")
            icloudExporter.state = .error("讀 cache 失敗: \(error.localizedDescription)")
        }
    }

    /// 產生 export filename: `<前10字 alphanum>-<yyyy-MM-dd-HHmmss>.mp3`
    /// (v0.7.8) Spec 由 Peter: filename 反映 user 輸入嘅文字 + 日期 + 時間
    /// HHmmss suffix 防止同分鐘重複 save 覆蓋問題 (e.g. 換 voice 試唔同效果)
    private func generateExportFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let dateStr = formatter.string(from: Date())
        let textSlug = makeTextSlug(from: inputText)
        return "\(textSlug)-\(dateStr).mp3"
    }

    /// 從 user 輸入文字抽取前 10 個 alphanum 字 (中英數字), 組成 filename 用 slug
    /// - 例子: "你好, 世界呀123! hello." → "你好世界呀123hel"
    /// - 例子: " 1234567890abcdef " → "1234567890"
    /// - 例子: "「「「" (全部 punctuation) → "tts" (fallback)
    private func makeTextSlug(from text: String) -> String {
        // 1) Keep alphanumeric only (CJK + a-z + A-Z + 0-9)
        let allowed = CharacterSet.alphanumerics
        let filteredScalars = text.unicodeScalars.filter { allowed.contains($0) }
        let filtered = String(String.UnicodeScalarView(filteredScalars))
        // 2) Take first 10
        let truncated = String(filtered.prefix(10))
        // 3) Fallback if empty
        return truncated.isEmpty ? "tts" : truncated
    }

    private func slugify(_ text: String) -> String {
        // (v0.7.8) Persona-based slug 唔再用 (改用 text slug),
        // 但保留呢個 helper 因為 test file 仍然 reference `slugifyForTest`
        let ascii = text.lowercased()
            .replacingOccurrences(of: " ", with: "-")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        return String(ascii.unicodeScalars.filter { allowed.contains($0) })
    }

    /// 用戶 navigation 走咗 (e.g. 撳 back button) — 確保 audio session 唔 leak
    /// 唔做 deinit 就會: 下一個 view 想用 mic 撞 AVAudioEngine 已有 in-flight state
    deinit {
        // ⚠️ deinit 唔係 @MainActor isolated, 但 AudioService 係
        // 用 MainActor.assumeIsolated 因為 TtsLabViewModel 本身 @MainActor
        // 現實: deinit 通常喺 main thread (SwiftUI lifecycle), 用 assumeIsolated 安全
        MainActor.assumeIsolated {
            if case .listening = self.speechState {
                self.audio.stopRecording()
                print("[TtsLab] deinit: 強行 stop 進行中嘅錄音, 免 leak audio session")
            }
        }
    }

    /// 文字或 persona 改變時 update cache badge
    func updateCacheBadge() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cacheState = .unknown
            return
        }
        let fp = fingerprint(voice: selectedPersona.voiceId, text: trimmed)
        if fp == lastPlayedFingerprint, lastPlayedCachePath != nil {
            cacheState = .hit
        } else {
            cacheState = .miss
        }
    }

    /// (v0.7.9+) AI 廣東話優化 — call LLM 將 inputText 改寫成更地道粵語口語
    /// - Persona-aware: system prompt 根據 selectedPersona 調整語氣
    /// - 混合: 修正 + 修飾 + 擴寫 (User spec)
    /// - Return: enhanced text (唔直接覆蓋 inputText, 由 UI 決定)
    /// - Error: throw — UI 顯示 banner
    func enhanceText() async throws -> String {
        let rawText = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else {
            state = .error("請先輸入文字先 enhance")
            throw NSError(domain: "TtsLab", code: -1, userInfo: [NSLocalizedDescriptionKey: "input text 空白"])
        }

        currentPlayer?.stop()
        currentPlayer = nil
        state = .enhancing
        print("[TtsLab] enhancing text: '\(rawText.prefix(50))...' for persona \(selectedPersona.rawValue)")

        do {
            let personaDesc = personaDescription(selectedPersona)
            let systemPrompt = """
            你係一個粵語 (Cantonese) copy editor. User 會用 TTS (語音合成) 讀出你改寫嘅文字, 所以:
            1. 必須保留完整粵語口語 (唔好用書面語, 唔好用普通話)
            2. 可以 修飾 / 修正 / 擴寫 — 跟用戶 persona 嘅語氣
            3. 唔好用 markdown, 唔好用 emoji, 唔好用引號
            4. 唔好加 「你係」, 「以下是」, 之類 prefix
            5. 直接輸出改寫後嘅粵語文字 (一句 / 幾句都得)

            當前 persona: \(personaDesc)
            """

            let userPrompt = "改寫呢段文字:「\(rawText)」"

            let messages = [
                MiniMaxService.ChatMessage(role: "system", content: systemPrompt),
                MiniMaxService.ChatMessage(role: "user", content: userPrompt)
            ]
            let result = try await service.chat(messages: messages)
            // Strip 任何 markdown fences, 引號, 換行
            let cleaned = result
                .replacingOccurrences(of: "```", with: "")
                .replacingOccurrences(of: "「", with: "")
                .replacingOccurrences(of: "」", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            print("[TtsLab] enhance done: '\(cleaned.prefix(50))...'")
            state = .idle
            return cleaned
        } catch {
            print("[TtsLab] enhance FAILED: \(error.localizedDescription)")
            state = .error("AI 優化失敗: \(error.localizedDescription)")
            throw error
        }
    }

    /// Persona → 語氣描述 (LLM prompt 用)
    private func personaDescription(_ p: Persona) -> String {
        switch p {
        case .chaChaanTang:   return "茶餐廳老闆輝哥, 講嘢直接、口語化, 鍾意用『嘅』『咗』『嘛』"
        case .taxiDriver:     return "的士司機強哥, 講嘢快、casual, 鍾意用『喂』『嘛』『啦』"
        case .youngster:      return "90後阿明, 後生仔, 講嘢 casual、用網絡潮語"
        case .aJie:           return "街市阿姐, 講嘢好嘈、好地道, 鍾意用『嗱』『喂』『啩』"
        case .aSir:           return "阿sir, 講嘢權威、稍正式"
        case .chengyuTeacher: return "成語老師陳sir, 講嘢斯文、引用典故, 適合教育語境"
        }
    }

    /// 主要 entry: 讀 inputText 嘅內容出嚟
    /// Cache-first → synthesize fallback
    func speak() async {
        let rawText = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else {
            state = .error("請輸入文字")
            return
        }

        currentPlayer?.stop()
        currentPlayer = nil
        state = .synthesizing

        let ttsText = CantonesePronunciation.shared.apply(to: rawText)
        let voice = selectedPersona.voiceId
        let fp = fingerprint(voice: voice, text: ttsText)

        // 1) Cache hit: 同 fingerprint 一致 + cache file 仲在
        if fp == lastPlayedFingerprint,
           let path = lastPlayedCachePath,
           let url = TTSCache.absoluteURL(for: path),
           let data = try? Data(contentsOf: url) {
            print("[TtsLab] cache hit: \(path) (\(data.count)B)")
            cacheState = .hit
            await playAudio(data: data, cachePath: path)
            return
        }

        // 2) Cache miss: synthesize + write cache
        do {
            let data = try await service.synthesize(text: ttsText, voiceId: voice)
            let path: String
            do {
                path = try TTSCache.write(data)
            } catch {
                // cache write 失敗 → 用 temp file 播 (唔 block playback)
                print("[TtsLab] cache write FAILED: \(error.localizedDescription) — 用 temp file")
                path = ""
            }
            print("[TtsLab] cache miss → synthesize OK (\(data.count)B), cached at \(path)")
            lastPlayedCachePath = path.isEmpty ? nil : path
            lastPlayedFingerprint = fp
            cacheState = path.isEmpty ? .miss : .hit
            await playAudio(data: data, cachePath: path.isEmpty ? nil : path)
        } catch {
            state = .error("TTS 失敗: \(error.localizedDescription)")
        }
    }

    /// 唔重新 synthesize, 純粹再播 lastPlayedCachePath
    /// 用戶撳「再聽一次」button 用
    func replayLast() async {
        guard let path = lastPlayedCachePath,
              let url = TTSCache.absoluteURL(for: path) else {
            state = .error("冇 cache 可重聽, 請先撳「讀出嚟」")
            return
        }
        currentPlayer?.stop()
        do {
            let data = try Data(contentsOf: url)
            print("[TtsLab] replay last: \(path) (\(data.count)B)")
            await playAudio(data: data, cachePath: path)
        } catch {
            state = .error("重聽失敗: \(error.localizedDescription)")
        }
    }

    // MARK: - Speech-to-text (v0.7.1)

    /// Tap-to-toggle: 撳一下開始錄音，再撳一下停 + transcribe
    /// Overwrite 模式: STT result 直接覆蓋 inputText
    /// 用咗 AGENTS.md 嘅 AAC encoder 500ms buffer pitfall — stopRecording 之後 sleep 500ms 再 STT
    func startListening() async {
        // (v0.7.5) Auto-recovery: 如果 stuck 喺 error state (e.g. STT 失敗冇 reset),
        // user 再撳 mic 應該 reset 返 idle, 唔需要 force quit app
        if case .error = speechState {
            print("[TtsLab] startListening: 從 error state 自動 reset → idle")
            speechState = .idle
        }
        guard speechState == .idle else {
            print("[TtsLab] startListening: not idle (state=\(speechState)), skip")
            return
        }

        speechState = .requestingPermission
        let granted = await audio.requestPermission()
        guard granted else {
            speechState = .error("Mic 權限被拒，請去 Settings 開")
            return
        }

        // 開始錄音
        audio.startRecording()
        speechState = .listening
        print("[TtsLab] listening…")
    }

    func stopListening() async {
        guard speechState == .listening else {
            print("[TtsLab] stopListening: not listening (state=\(speechState)), skip")
            return
        }

        speechState = .transcribing

        // 1) Stop recording 拎 URL
        guard let audioURL = audio.stopRecording() else {
            speechState = .error("錄音失敗，冇 audio file")
            return
        }

        // 2) AAC encoder buffer flush — AGENTS.md pitfall: 必須 sleep 500ms
        //    否則 on-device zh-HK 認唔到最後嗰幾個字
        try? await Task.sleep(nanoseconds: 500_000_000)

        // 3) Transcribe
        do {
            let text = try await recognizer.transcribe(audioURL: audioURL, language: "yue")
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                // Append mode (v0.7.2): STT result append 到現有 inputText 嘅下面
                // 用 newline 分隔, 方便多段語音串連
                if self.inputText.isEmpty {
                    self.inputText = trimmed
                    print("[TtsLab] STT OK (\(trimmed.count) chars), inputText was empty, set to STT result")
                } else {
                    // 確保 newline: 已有 text 以 newline 結尾先直接 append, 否則加 newline
                    let separator = self.inputText.hasSuffix("\n") ? "" : "\n"
                    self.inputText += separator + trimmed
                    print("[TtsLab] STT OK (\(trimmed.count) chars), appended to inputText (now \(self.inputText.count) chars)")
                }
            } else {
                print("[TtsLab] STT returned empty, leaving inputText unchanged")
            }
            self.speechState = .idle
            // STT result 改變咗 text, update cache badge
            self.updateCacheBadge()
            // Clean up temp file
            try? FileManager.default.removeItem(at: audioURL)
        } catch {
            print("[TtsLab] STT FAILED: \(error.localizedDescription)")
            // (v0.7.7+) 將 technical iOS Speech framework 嘅 verbose error (e.g. "code 1110:No speech detected")
            // 翻譯做 user-friendly 提示
            let userMsg = Self.userFriendlySTTError(error)
            self.speechState = .error(userMsg)
            // (v0.7.5) 3s 後 auto-reset error → idle (banner 顯示夠耐睇, 然後 user 可 retry 唔 force quit)
            let errorMsg = userMsg
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                // 只 reset 如果仲係同一個 error (避免覆蓋後續 state)
                if case .error(let currentMsg) = self?.speechState, currentMsg == errorMsg {
                    self?.speechState = .idle
                    print("[TtsLab] STT error auto-reset → idle (after 3s)")
                }
            }
        }
    }

    /// 公開 helper: View layer 根據 speechState 決定 mic button 行為
    var isListening: Bool {
        if case .listening = speechState { return true }
        return false
    }

    // MARK: - Helpers

    /// (v0.7.7+) 將 technical iOS Speech framework 嘅 verbose error 翻譯做 user-friendly 提示。
    /// e.g. "code 1110:No speech detected" → "語音辨識失敗: 請重試"
    /// - 1110: 冇偵測到語音
    /// - 1101/1107: 用戶 cancel / 被打斷
    /// - 203: 語音太短
    /// - 其他: 保留 generic message (有 info 喺度方便 debug)
    static func userFriendlySTTError(_ error: Error) -> String {
        let raw = error.localizedDescription
        let lower = raw.lowercased()
        if lower.contains("1110") || lower.contains("no speech detected") {
            return "語音辨識失敗: 請重試"
        }
        if lower.contains("1101") || lower.contains("cancel") {
            return "語音辨識失敗: 已取消"
        }
        if lower.contains("1107") || lower.contains("interrupted") {
            return "語音辨識失敗: 被中斷, 請重試"
        }
        if lower.contains("203") || lower.contains("too short") {
            return "語音辨識失敗: 講太短, 請再嚟多次"
        }
        return "語音辨識失敗: \(raw)"
    }

    private func fingerprint(voice: String, text: String) -> String {
        return "\(voice)|\(text)"
    }

    private func playAudio(data: Data, cachePath: String?) async {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        let playURL: URL
        if let p = cachePath, let cached = TTSCache.absoluteURL(for: p) {
            playURL = cached
        } else {
            playURL = FileManager.default.temporaryDirectory.appendingPathComponent("ttslab-\(UUID().uuidString).mp3")
            try? data.write(to: playURL)
        }
        do {
            let player = try AVAudioPlayer(contentsOf: playURL)
            player.numberOfLoops = 0
            player.play()
            currentPlayer = player
            state = .playing
            while player.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            state = .idle
        } catch {
            state = .error("播放失敗: \(error.localizedDescription)")
        }
    }
}
