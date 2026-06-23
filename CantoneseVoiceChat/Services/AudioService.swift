import Foundation
import AVFoundation
import Combine

/// 錄音相關抽象, 用嚟 inject mock 入 VM 做 unit test
@MainActor
protocol AudioRecording: AnyObject {
    func requestPermission() async -> Bool
    func startRecording()
    func stopRecording() -> URL?
}

/// 負責錄音、播放、回調 audio level
@MainActor
final class AudioService: NSObject, ObservableObject, AudioRecording {
    @Published var isRecording: Bool = false
    @Published var isPlaying: Bool = false
    @Published var audioLevel: Float = 0.0  // 0...1, 用嚟做 ripple 動畫
    @Published var lastError: String?

    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?
    private var player: AVAudioPlayer?

    // 揾 temp 路徑
    private func makeTempURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("rec-\(UUID().uuidString).m4a")
    }

    func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }

    // MARK: - Recording
    func startRecording() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)

            recordingURL = makeTempURL()
            let input = engine.inputNode
            // Sim 個 input.outputFormat 有時會報 0 channels / 0 sample rate
            // (冇真 mic), 用 hardcoded sim-friendly settings 落 AVAudioFile,
            // 但 tap 仍然用 input 真 format 確保收到任何 input
            let inputFormat = input.outputFormat(forBus: 0)
            let simSafeSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: inputFormat.sampleRate > 0 ? inputFormat.sampleRate : 16000.0,
                AVNumberOfChannelsKey: inputFormat.channelCount > 0 ? inputFormat.channelCount : 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            audioFile = try AVAudioFile(forWriting: recordingURL!, settings: simSafeSettings)

            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                guard let self else { return }
                try? self.audioFile?.write(from: buffer)
                // 計 level (RMS)
                let level = Self.rmsLevel(buffer: buffer)
                // (v0.7.9+) Wrap SpeakerProfile.update 喺 MainActor —
                // SpeakerProfile 整個 class @MainActor 咗, 唔 dispatch 會 compile error
                // ("Call to main actor-isolated instance method 'update' in a synchronous nonisolated context")
                Task { @MainActor in
                    SpeakerProfile.shared.update(level: level, audioBuffer: buffer)
                }
                Task { @MainActor in
                    self.audioLevel = level
                }
            }

            engine.prepare()
            try engine.start()
            isRecording = true
        } catch {
            lastError = "錄音失敗: \(error.localizedDescription)"
        }
    }

    func stopRecording() -> URL? {
        // 1) 即時 remove tap 阻新 frame 入嚟
        engine.inputNode.removeTap(onBus: 0)
        // 2) 等 100ms 俾 in-flight AAC frame 寫完 (file write 係 async 排隊)
        Thread.sleep(forTimeInterval: 0.1)
        // 3) Stop engine
        engine.stop()
        isRecording = false
        audioLevel = 0
        let url = recordingURL
        recordingURL = nil
        audioFile = nil
        return url
    }

    // MARK: - VAD-driven continuous recording
    /// 開一段持續錄音, VAD 自動決定幾時 stop, 通過 callback `onSpeechEnd` 通知
    /// 適合 hands-free mode: 撳一下 mic 開始, VAD 偵測到 user 停咗就自動 STT → LLM → TTS
    func startContinuousRecording(
        onSpeechEnd: @escaping (URL) -> Void,
        onLevelUpdate: ((Float) -> Void)? = nil
    ) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)

            // 撈 fresh URL 畀今輪
            let url = makeTempURL()
            continuousCurrentURL = url
            continuousURLStack = [url]
            recordingURL = url

            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            let simSafeSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: inputFormat.sampleRate > 0 ? inputFormat.sampleRate : 16000.0,
                AVNumberOfChannelsKey: inputFormat.channelCount > 0 ? inputFormat.channelCount : 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            audioFile = try AVAudioFile(forWriting: url, settings: simSafeSettings)

            // 將 onSpeechEnd 保留畀 cancel 嘅 cleanup 用
            continuousOnEnd = { [weak self] in
                guard let self else { return }
                let finalURL = self.continuousCurrentURL ?? url
                self.engine.inputNode.removeTap(onBus: 0)
                self.engine.stop()
                self.isRecording = false
                self.audioLevel = 0
                self.audioFile = nil
                self.recordingURL = nil
                self.continuousCurrentURL = nil
                onSpeechEnd(finalURL)
            }

            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                guard let self else { return }
                try? self.audioFile?.write(from: buffer)
                let level = Self.rmsLevel(buffer: buffer)
                Task { @MainActor in
                    self.audioLevel = level
                    onLevelUpdate?(level)
                }
            }

            engine.prepare()
            try engine.start()
            isRecording = true
        } catch {
            lastError = "錄音失敗: \(error.localizedDescription)"
        }
    }

    /// 連續 mode 期間 VAD 偵測到 silence, 開新一段 file 預備下一輪
    /// (避免單 file 太大同時保留每段 speech)
    func rotateContinuousFile() {
        guard let stack = continuousURLStack, !stack.isEmpty else { return }
        // close current
        audioFile = nil
        // open new
        let newURL = makeTempURL()
        continuousCurrentURL = newURL
        continuousURLStack?.append(newURL)
        recordingURL = newURL
        do {
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            let simSafeSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: inputFormat.sampleRate > 0 ? inputFormat.sampleRate : 16000.0,
                AVNumberOfChannelsKey: inputFormat.channelCount > 0 ? inputFormat.channelCount : 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            audioFile = try AVAudioFile(forWriting: newURL, settings: simSafeSettings)
        } catch {
            lastError = "rotate file failed: \(error.localizedDescription)"
        }
    }

    /// 取消連續錄音 (冇 callback)
    func cancelContinuousRecording() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        audioLevel = 0
        audioFile = nil
        recordingURL = nil
        continuousURLStack = nil
        continuousCurrentURL = nil
        continuousOnEnd = nil
    }

    /// VAD 偵測到 speech end → trigger 連續 mode 嘅 finalize
    /// 等 audio engine stop, 個 file 寫完
    func triggerContinuousEnd() {
        continuousOnEnd?()
    }

    // 連續 mode 狀態
    var continuousURLStack: [URL]?
    var continuousCurrentURL: URL?
    private var continuousOnEnd: (() -> Void)?

    var currentContinuousURL: URL? { continuousCurrentURL }
    var continuousStack: [URL]? { continuousURLStack }

    /// 拎最後寫入嘅一段音 URL (用於 VAD 結束後拎 transcript file)
    func lastContinuousURL() -> URL? {
        continuousURLStack?.last ?? continuousCurrentURL
    }

    // MARK: - Playback
    func playAudioFile(at url: URL) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)

            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.prepareToPlay()
            player?.play()
            isPlaying = true
        } catch {
            lastError = "播放失敗: \(error.localizedDescription)"
        }
    }

    func stopPlayback() {
        player?.stop()
        isPlaying = false
    }

    // MARK: - Helpers
    static func rmsLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<frameLength {
            let s = channelData[i]
            sum += s * s
        }
        let rms = sqrt(sum / Float(frameLength))
        // map to 0...1
        return min(max(rms * 4, 0), 1)
    }
}

extension AudioService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
        }
    }
}
