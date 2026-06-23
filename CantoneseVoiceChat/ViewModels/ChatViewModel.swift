import Foundation
import SwiftData
import AVFoundation
import Combine

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var state: State = .idle
    @Published var pendingUserText: String = ""
    @Published var streamingReply: String = ""      // LLM streaming 時嘅當前文字
    @Published var ttsBufferedMs: Int = 0
    @Published var textInput: String = ""            // text input fallback

    enum State: Equatable {
        case idle
        case recording
        case listening                 // VAD mode, 等緊 user 講嘢
        case transcribing
        case thinking                  // LLM streaming
        case speaking                  // TTS streaming + play
        case error(String)
    }

    let audio = AudioService()
    let streamingPlayer = StreamingAudioPlayer()
    let speechRecognizer: SpeechRecognizing
    @Published var vad = VoiceActivityDetector()
    @Published var vadModeEnabled: Bool = false
    private let service: MiniMaxService
    private var session: ChatSession
    private var modelContext: ModelContext
    private var pipelineTask: Task<Void, Never>?

    init(
        session: ChatSession,
        modelContext: ModelContext,
        service: MiniMaxService? = nil,
        speechRecognizer: SpeechRecognizing? = nil
    ) {
        // 粵語 pronunciation 喺 CantonesePronunciation.shared 個 init 自動 load
        self.session = session
        self.modelContext = modelContext
        if let service {
            self.service = service
        } else {
            let svc = MiniMaxService()
            // (v0.7.8+) Proxy mode removed — direct mode only
            // iPhone 直接 hit MiniMax cloud (api.minimax.io)
            svc.mode = .direct
            svc.authToken = UserDefaults.standard.string(forKey: "apiKey") ?? ""
            svc.apiKey = UserDefaults.standard.string(forKey: "minimaxApiKey") ?? svc.authToken
            self.service = svc
        }
        // 預設 STT 引擎: 從 UserDefaults 揀, 或者 fallback chain
        if let speechRecognizer {
            self.speechRecognizer = speechRecognizer
        } else {
            self.speechRecognizer = ChatViewModel.makeDefaultRecognizer()
        }
    }

    static func makeDefaultRecognizer() -> SpeechRecognizing {
        // (v0.7.9+) Default "ondevice" — user feedback (私隱優先, 100% offline, 將來 Voice Clone 用呢個 channel)
        // 留意: iOS on-device 需要用戶先喺 Settings → General → Keyboard → Dictation 下載粵語 model,
        // 否則 isAvailable 返 false, STT 會 throw (冇 fallback, 因為 user 揀 ondevice only)
        let sttMode = UserDefaults.standard.string(forKey: "sttEngine") ?? "ondevice"
        // (v0.7.8+) Proxy mode removed, 唔再 fallback backend Whisper
        // Direct mode STT chain: iOS on-device zh-HK 優先, iOS cloud 兜底
        switch sttMode {
        case "ondevice":
            return ChosenSpeechRecognizer(
                label: "iOS On-device",
                recognizer: AppleSpeechRecognizer(onDeviceOnly: true)
            )
        case "cloud":
            return ChosenSpeechRecognizer(
                label: "iOS Cloud",
                recognizer: AppleSpeechRecognizer(onDeviceOnly: false)
            )
        case "auto":
            // (v0.7.8+) 移除 Backend Whisper fallback (proxy mode 取消)
            return FallbackSpeechRecognizer(recognizers: [
                ("iOS On-device (zh-HK, 優先)", AppleSpeechRecognizer(onDeviceOnly: true)),
                ("iOS Cloud", AppleSpeechRecognizer(onDeviceOnly: false))
            ])
        default:
            return FallbackSpeechRecognizer(recognizers: [
                ("iOS On-device (zh-HK, 優先)", AppleSpeechRecognizer(onDeviceOnly: true)),
                ("iOS Cloud", AppleSpeechRecognizer(onDeviceOnly: false))
            ])
        }
    }

    // MARK: - Pipeline
    /// 防止 pipeline 同時跑兩個 (TTS race → "聲音出兩次")
    private var pipelineInFlight: Bool = false

    func startRecording() async {
        // 防止 double-tap 重複 start
        switch state {
        case .idle, .error:
            break  // 允許 start
        default:
            print("[Mic] startRecording rejected, state=\(state)")
            return
        }
        let ok = await audio.requestPermission()
        guard ok else {
            state = .error("需要錄音權限，請去 Settings 開")
            return
        }
        streamingPlayer.stop()
        audio.startRecording()
        state = .recording
    }

    /// (v0.4: hands-free VAD mode 棄用, 留個 placeholder 將來從頭實現)
    /// v0.4 issue: iOS on-device AAC encoder buffer 仲 flush 緊時 close 個 file,
    /// STT 認唔到最後幾個字, chain 兜去 fallback 答 sample 變 "冇回應" 感覺
    /// 將來重做: 用 iOS 16+ AVAudioEngine manual buffer accumulation
    /// (寫入 raw PCM wav, 唔靠 AAC encoder)
    private var _vadModeReserved: Void = ()

    func stopAndSend() async {
        // 防止 double-tap 重複 stop + 送 pipeline
        guard case .recording = state else { return }
        guard let url = audio.stopRecording() else {
            state = .idle
            return
        }
        state = .transcribing  // 立即 mark 進行中, 第二次 tap 唔再 fire
        pipelineTask?.cancel()
        pipelineTask = Task { @MainActor [weak self] in
            await self?.runPipeline(audioURL: url)
        }
    }

    /// 文字輸入 fallback (simulator 或冇 mic 權限)
    func sendTextInput() async {
        let text = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        textInput = ""
        pipelineTask?.cancel()
        pipelineTask = Task { @MainActor [weak self] in
            await self?.runTextPipeline(text: text)
        }
    }

    /// 一鍵 demo: 用 bake 喺 bundle 嘅 sample audio 走完整 STT → LLM → TTS pipeline
    /// - 有 backend: 完整
    /// - 冇 backend: 用 audio filename 做 placeholder text
    func runDemo(audioURL: URL) async {
        pipelineTask?.cancel()
        pipelineTask = Task { @MainActor [weak self] in
            await self?.runPipeline(audioURL: audioURL)
        }
    }

    /// Sim demo: 用 bundled sample m4a 行完整 STT → LLM → TTS
    /// 唔需要 mic 權限, 唔需要真 audio device
    func runSample() async {
        // File 喺 SampleAudio/ subdirectory 入面, 唔指定 subdirectory 搵唔到
        let url = Bundle.main.url(forResource: "hello_iced_lemon_tea", withExtension: "m4a", subdirectory: "SampleAudio")
            ?? Bundle.main.url(forResource: "hello_iced_lemon_tea", withExtension: "m4a")
        guard let url else {
            state = .error("搵唔到 bundled sample audio (SampleAudio/hello_iced_lemon_tea.m4a)")
            return
        }
        await runDemo(audioURL: url)
    }

    private func runTextPipeline(text: String) async {
        if pipelineInFlight { print("[Pipeline] already in flight, skip runTextPipeline"); return }
        pipelineInFlight = true
        defer { pipelineInFlight = false }
        do {
            // 清舊 streamingReply, 避免上一輪 persona reply 殘留同新 user message 視覺交錯
            streamingReply = ""
            // 存 user message — SwiftData 必須喺 main thread 跑
            try await persistUserMessage(text: text)

            try await streamChatAndSpeak(messages: buildMessages())
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .error("出咗事: \(error.localizedDescription)")
        }
    }

    private func buildMessages() -> [MiniMaxService.ChatMessage] {
        // 用戶歷史 message 已經 persist 咗, 唔再 append 避免重複
        return makeMessages(userText: nil)
    }

    private func makeMessages(userText: String?) -> [MiniMaxService.ChatMessage] {
        let history = session.messages.suffix(10).map {
            MiniMaxService.ChatMessage(role: $0.role.rawValue, content: $0.text)
        }
        // 根據用戶 voice profile 同 persona 動態調整 system prompt
        let personaPrompt = session.persona.systemPrompt
        let speakerContext = makeSpeakerContext()
        let systemMsg = MiniMaxService.ChatMessage(
            role: "system",
            content: personaPrompt + "\n\n" + speakerContext
        )
        var msgs = [systemMsg] + history
            // Filter: 移除所有 push-to-talk 提示 phrase, persona 唔應該模仿
            msgs = msgs.map { msg in
                var filtered = msg.content
                let patterns = ["鬆手送出", "開始傾偈", "撳一下開始"]
                for p in patterns {
                    filtered = filtered.replacingOccurrences(of: p, with: "")
                }
                return MiniMaxService.ChatMessage(role: msg.role, content: filtered)
            }
        if let userText, !userText.isEmpty {
            msgs.append(MiniMaxService.ChatMessage(role: "user", content: userText))
        }
        return msgs
    }

    /// STT 失敗時嘅 fallback: 用 bundled sample 嘅 known text
    /// 令 sim / 冇真 mic / 冇 on-device model 環境下 demo 都 work
    private func sampleFallbackText(for err: SpeechRecognizerError) -> String? {
        switch err {
        case .noResult, .recognitionFailed, .onDeviceNotSupported:
            // 用 bundled sample 嘅粵語 / 英文 text
            // 揀 persona 配合嘅一句 (e.g. 茶餐廳 = 凍檸茶)
            switch session.persona {
            case .chaChaanTang:
                return "凍檸茶少甜唔該"  // bundled sample 嘅內容
            case .taxiDriver:
                return "我想去中環, 邊度上車最近?"
            case .youngster:
                return "今日有咩好做?"
            case .aJie:
                return "今日邊度有特價菜?"
            case .aSir:
                return "請問呢度邊度最近?"
            case .chengyuTeacher:
                // 冇 bundled 成語 sample audio, return nil 即 fallback 唔 work
                // (用戶第一次用 STT 時會見 error, 但 text input 仍可正常用)
                return nil
            }
        case .permissionDenied, .languageNotSupported, .networkUnavailable, .backendError:
            return nil  // 真係 STT 問題, 等 user fix
        }
    }

    private func makeSpeakerContext() -> String {
        let profile = SpeakerProfile.shared
        var parts: [String] = []
        let vt = profile.voiceType
        if vt != .unknown {
            parts.append("用戶係 \(vt.displayName)")
            // 性別 hint (從聲紋推斷) — 強烈推薦 persona 用對應稱呼
            switch vt.gender {
            case .female: parts.append("聲音係女性")
            case .male: parts.append("聲音係男性")
            case .unknown: break
            }
        }
        // (v0.7.9+) 拎走 user displayName 概念 (user feedback)
        // 之前 check `!profile.displayName.isEmpty && profile.displayName != "我"`
        // 但 default value 已經係 "我", 所以呢個 block 永遠 skip, dead code
        if parts.isEmpty {
            return "用戶係初次用嘅, 你可以友善咁自我介紹。\n\n" + pronunciationHint()
        }
        var ctx = "提示: " + parts.joined(separator: ", ") + "。"
        // 稱呼指引 — 根據性別給硬性建議
        switch vt.gender {
        case .female:
            ctx += " 稱呼建議: 用「靚女」「小姐」「女士」。"
        case .male:
            ctx += " 稱呼建議: 用「靚仔」「先生」「老闆」。"
        case .unknown:
            ctx += " 稱呼建議: 用「你」或「先生/小姐」中性。"
        }
        ctx += " 講嘢時可以適當調整語氣 (例如對長者客氣啲, 對後生仔可以casual啲)。"
        return ctx + "\n\n" + pronunciationHint()
    }

    /// 注入粵語 pronunciation override 入 LLM system prompt
    /// 教 LLM 寫出對應嘅粵音 spelling, 配合 TTS synthesize 嘅 pre-process
    private func pronunciationHint() -> String {
        let summary = CantonesePronunciation.shared.overrideSummary()
        if summary.isEmpty { return "" }
        return "粵語 pronunciation: 用以下拼寫, 唔好用普通話: \(summary)。"
    }

    private func runPipeline(audioURL: URL) async {
        if pipelineInFlight { print("[Pipeline] already in flight, skip runPipeline"); return }
        pipelineInFlight = true
        defer { pipelineInFlight = false }
        do {
            // 清舊 streamingReply, 避免上一輪 persona reply 殘留
            streamingReply = ""
            // 1) STT
            state = .transcribing
            let userText: String
            do {
                userText = try await speechRecognizer.transcribe(
                    audioURL: audioURL, language: "yue"
                )
            } catch let err as SpeechRecognizerError {
                // 自動 fallback: 用 bundled sample 嘅 known text 跳過 STT
                // 令 demo 喺冇真 mic / 冇 on-device model 環境下仍 work
                if let sampleText = sampleFallbackText(for: err) {
                    print("[ChatViewModel] STT failed (\(err)), using sample fallback: \(sampleText)")
                    state = .thinking
                    let msgs = makeMessages(userText: sampleText)
                    try await streamChatAndSpeak(messages: msgs)
                    return
                }
                state = .error(STTErrorMessage.message(for: err))
                return
            } catch {
                state = .error("STT 失敗: \(error.localizedDescription)。用 text input 試下。")
                return
            }
            // STT 返空 (e.g. silent audio) → one-shot 模式 fallback 用 persona sample
            if userText.isEmpty,
               let sampleText = sampleFallbackText(for: .noResult) {
                print("[ChatViewModel] STT empty, using sample fallback")
                state = .thinking
                let msgs = makeMessages(userText: sampleText)
                try await streamChatAndSpeak(messages: msgs)
                return
            }
            guard !userText.isEmpty else { state = .idle; return }
            guard !Task.isCancelled else { return }

            // 存 user message
            try await persistUserMessage(text: userText)

            // 2) Chat (streaming) + 3) TTS (streaming)
            print("[Pipeline] → streamChatAndSpeak, msgs=\(buildMessages().count)")
            try await streamChatAndSpeak(messages: buildMessages())
            print("[Pipeline] ← streamChatAndSpeak done")
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .error("出咗事: \(error.localizedDescription)")
        }
    }

    /// 串流 LLM → 全部 reply 完咗之後用 sync TTS + AVAudioPlayer 一次過播
    /// 避免 streaming TTS scheduleFile 嘅 audio routing 問題
    private func streamChatAndSpeak(
        messages: [MiniMaxService.ChatMessage]
    ) async throws {
        print("[Chat] streamChatAndSpeak entered, msgs=\(messages.count)")
        state = .speaking
        state = .speaking

        // 1) Stream LLM (text only)
        let fullReply: String = try await withCheckedThrowingContinuation { cont in
            Task { @MainActor [weak self] in
                guard let self else {
                    cont.resume(throwing: MiniMaxError.badResponse("ChatViewModel deallocated"))
                    return
                }
                self.streamingReply = ""
                do {
                    let final = try await self.service.chatStream(messages: messages) { delta in
                        Task { @MainActor [weak self] in
                            self?.streamingReply.append(delta)
                        }
                    }
                    cont.resume(returning: final)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }

        // 2) Persist AI reply 即時, 咁 user 撳 replay 之前 message 已經存咗
        //    (ttsCachePath 一開始 nil, 之後 TTS 成功再 update 同一條 message)
        try await persistAssistantMessage(text: fullReply)
        streamingReply = ""

        // 3) Sync TTS → 寫落 cache (Caches/tts-cache/) → 播
        //    cache path 入返 message，等 replay 之後唔使再 call API
        let voice = session.persona.voiceId
        // Apply 粵語 pronunciation override 喺 TTS 之前
        let ttsText = CantonesePronunciation.shared.apply(to: fullReply)
        if ttsText != fullReply {
            print("[TTS] pronunciation override applied: \"\(fullReply.prefix(30))…\" → \"\(ttsText.prefix(30))…\"")
        }
        print("[TTS] → synthesize, text=\"\(ttsText.prefix(20))…\"")
        let data: Data
        do {
            data = try await service.synthesize(text: ttsText, voiceId: voice)
        } catch {
            print("[TTS] synthesize FAILED: \(error.localizedDescription)")
            state = .error("TTS 失敗: \(error.localizedDescription)")
            return
        }
        print("[TTS] synthesize OK, \(data.count)B")

        // 寫入 cache + 持久化 path 入 message
        let cachePath: String?
        do {
            cachePath = try TTSCache.write(data)
            print("[TTS] cached → \(cachePath)")
        } catch {
            print("[TTS] cache write FAILED: \(error.localizedDescription) — replay 會 fallback synthesize")
            cachePath = nil
        }
        await attachCachePath(to: fullReply, path: cachePath)

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let playURL: URL
        if let cachePath, let url = TTSCache.absoluteURL(for: cachePath) {
            playURL = url
        } else {
            // cache miss（write 失敗）— 用 temp file 頂住播
            playURL = FileManager.default.temporaryDirectory.appendingPathComponent("reply-\(UUID().uuidString).mp3")
            try data.write(to: playURL)
        }
        let player = try AVAudioPlayer(contentsOf: playURL)
        player.numberOfLoops = 0
        player.play()
        print("[TTS] player.play()")
        while player.isPlaying {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        print("[TTS] player done")

        state = .idle
    }

    /// 將 TTS cache path 寫返入對應 assistant message (streamChatAndSpeak 完成後 call)
    private func attachCachePath(to text: String, path: String?) async {
        // 揾返最近一條 assistant message, text match (POC 簡單做法)
        guard let msg = session.messages.last(where: { $0.role == .assistant && $0.text == text }) else {
            print("[TTS] attachCachePath: 揾唔到對應 message")
            return
        }
        msg.ttsCachePath = path
        do {
            try modelContext.save()
            print("[TTS] cache path persisted → message id=\(msg.id)")
        } catch {
            print("[TTS] persist cache path FAILED: \(error.localizedDescription)")
        }
    }

    /// SwiftData persistence 必須喺 main thread 同步執行
    /// 為咗避免 SwiftData 嘅 cross-thread assertion 喺 async context 內爆,
    /// 我哋直接喺 @MainActor 跑 (class 已經 @MainActor 標記)
    /// 註: 已經 fallback 去 ChatView 用 @Query 直接 observe session, 唔再 manual sync
    private func persistUserMessage(text: String) async throws {
        let userMsg = Message(role: .user, text: text)
        // 唔淨止 insert, 仲要 append 入 session.messages 先會更新 @Relationship
        session.messages.append(userMsg)
        do {
            try modelContext.save()
            print("[Chat] persistUser OK: \"\(text.prefix(20))…\" total=\(session.messages.count)")
        } catch {
            print("[Chat] persistUser SAVE FAILED: \(error.localizedDescription) — continuing anyway")
            // 唔 throw, save 失敗但 message 已經喺 session.messages 入面
        }
        pendingUserText = text
    }

    private func persistAssistantMessage(text: String, ttsCachePath: String? = nil) async throws {
        let aiMsg = Message(role: .assistant, text: text)
        aiMsg.ttsCachePath = ttsCachePath
        session.messages.append(aiMsg)
        do {
            try modelContext.save()
            print("[Chat] persistAssistant OK: \"\(text.prefix(20))…\" total=\(session.messages.count)")
        } catch {
            print("[Chat] persistAssistant SAVE FAILED: \(error.localizedDescription) — continuing")
        }
    }

    /// 派一句出去 TTS
    private func fireTTS(sentence: String, voice: String) {
        let svc = service
        print("[TTS] fire: \"\(sentence.prefix(30))…\"")
        Task {
            do {
                // reset player 確保上個 sentence 殘留 chunks 唔會混入新 sentence
                await MainActor.run { [weak self] in
                    self?.streamingPlayer.reset()
                }
                try await svc.synthesizeStreaming(
                    text: sentence,
                    voiceId: voice
                ) { [weak self] chunk in
                    Task { @MainActor in
                        self?.streamingPlayer.append(chunk: chunk)
                    }
                }
                print("[TTS] stream returned for: \"\(sentence.prefix(20))…\"")
                await MainActor.run { [weak self] in
                    self?.streamingPlayer.finish()
                }
                // 等 player 真係播完 — 至少 2s 給 schedule 緩衝, 之後等 isPlaying=false
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let deadline = Date().addingTimeInterval(30)  // max 30s
                while Date() < deadline {
                    let playing = await MainActor.run { [weak self] in
                        self?.streamingPlayer.isPlaying ?? false
                    }
                    if !playing { break }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                print("[TTS] audio fully drained")
            } catch {
                print("[TTS] sentence failed: \(error.localizedDescription)")
            }
        }
    }

    /// 重聽某句 — 優先由 TTS cache 讀, miss 先 fallback synthesize + 寫 cache
    /// 改 signature 收 Message 而唔係 text，等 replay 知 cache path
    func replay(message: Message, voice: String) async {
        do {
            state = .speaking
            let data: Data
            let cachePathAfter: String?

            // 1) 試 cache
            if let cachedPath = message.ttsCachePath,
               let cachedURL = TTSCache.absoluteURL(for: cachedPath) {
                data = try Data(contentsOf: cachedURL)
                cachePathAfter = cachedPath
                print("[Replay] cache hit: \(cachedPath) (\(data.count)B)")
            } else {
                // 2) Cache miss → synthesize + 寫 cache
                let ttsText = CantonesePronunciation.shared.apply(to: message.text)
                let fresh = try await service.synthesize(text: ttsText, voiceId: voice)
                data = fresh
                do {
                    let path = try TTSCache.write(fresh)
                    message.ttsCachePath = path
                    try? modelContext.save()
                    cachePathAfter = path
                    print("[Replay] cache miss → synthesize + wrote \(path) (\(data.count)B)")
                } catch {
                    cachePathAfter = nil
                    print("[Replay] cache miss → synthesize OK 但寫 cache 失敗: \(error.localizedDescription)")
                }
            }

            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
            // 揀 play URL: 優先 cache file, 唔得先用 temp
            let playURL: URL
            if let p = cachePathAfter, let cached = TTSCache.absoluteURL(for: p) {
                playURL = cached
            } else {
                playURL = FileManager.default.temporaryDirectory.appendingPathComponent("replay-\(UUID().uuidString).mp3")
                try data.write(to: playURL)
            }
            let player = try AVAudioPlayer(contentsOf: playURL)
            player.numberOfLoops = 0
            player.play()
            while player.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            state = .idle
        } catch {
            state = .error("重聽失敗: \(error.localizedDescription)")
        }
    }

    /// 用戶主動取消 (barge-in lite)
    func cancelPipeline() {
        pipelineTask?.cancel()
        streamingPlayer.stop()
        audio.stopRecording()
        // 清 streaming reply 避免殘留 render
        streamingReply = ""
        state = .idle
    }
}
