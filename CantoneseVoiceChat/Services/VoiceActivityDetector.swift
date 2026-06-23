import Foundation

/// Voice Activity Detection (VAD) — 用 audio RMS level 簡單判斷 user 喺唔喺度講嘢
///
/// 設計目標: 即時 (latency < 100ms), 0 dependency (唔使 CoreML / ONNX)
/// 限制: 嘈雜環境會 false positive, 但對 casual 對話夠用
///
/// Threshold 設計:
///   - Silence: RMS < silenceThreshold (~0.01)
///   - Speech: RMS >= silenceThreshold
///   - 開始講嘢: 連續 speechFrames 個 frame 都係 speech (>80ms)
///   - 停咗: 連續 silenceFrames 個 frame 都係 silence (>600ms)
@MainActor
final class VoiceActivityDetector: ObservableObject {

    enum State: Equatable {
        case idle
        case listening    // 等緊 user 開始講
        case speaking     // user 講緊
        case silending    // user 講完, 緩衝 (VAD tail)
    }

    @Published var state: State = .idle
    @Published var currentLevel: Float = 0   // smoothed RMS 0-1
    @Published var speechDuration: TimeInterval = 0

    /// 設定 (可調)
    var silenceThreshold: Float = 0.012   // RMS threshold
    var speechFramesToTrigger: Int = 4     // ~80ms @ 20ms/frame
    var silenceFramesToStop: Int = 30      // ~600ms @ 20ms/frame
    var maxSpeechDuration: TimeInterval = 30  // 30s 自動停 (避免無限錄)
    var minSpeechDuration: TimeInterval = 0.4  // 太短嘅 burst 當 noise, 唔 trigger

    private var speechFrameCount = 0
    private var silenceFrameCount = 0
    private var startTime: Date?
    /// frames since speech start (用嚟 estimate duration when 冇 wall clock)
    private var framesSinceSpeechStart: Int = 0
    private let frameDuration: TimeInterval = 0.02  // 20ms/frame

    // Callbacks
    var onSpeechStart: (() -> Void)?
    var onSpeechEnd: (() -> Void)?   // called when minSpeechDuration 達標

    func feed(level: Float) {
        // smoothed level (exponential moving average, alpha=0.4)
        currentLevel = currentLevel * 0.6 + level * 0.4

        let isSpeech = currentLevel >= silenceThreshold
        if isSpeech {
            speechFrameCount += 1
            silenceFrameCount = 0
        } else {
            silenceFrameCount += 1
            speechFrameCount = 0
        }

        // 開始: listening → speaking
        if state == .listening, speechFrameCount >= speechFramesToTrigger {
            transition(to: .speaking)
            startTime = Date()
            framesSinceSpeechStart = 0
        }

        // 用戶講緊中, 累積 duration
        if state == .speaking {
            framesSinceSpeechStart += 1
            // 優先用 wall clock, 但 test 入面 wall clock 可能無 advance,
            // 所以用 frame-based 估算都 update speechDuration
            if let startTime {
                speechDuration = Date().timeIntervalSince(startTime)
            } else {
                speechDuration = Double(framesSinceSpeechStart) * frameDuration
            }
            // 超過 max, 自動停
            if speechDuration >= maxSpeechDuration {
                handleSpeechEnd()
            }
        }

        // 用戶停咗: speaking → idle
        if state == .speaking, silenceFrameCount >= silenceFramesToStop {
            handleSpeechEnd()
        }
    }

    /// 強制停 (cancel)
    func forceStop() {
        guard state != .idle else { return }
        // forceStop 唔 trigger onSpeechEnd (用戶主動取消)
        state = .idle
        speechFrameCount = 0
        silenceFrameCount = 0
        speechDuration = 0
        framesSinceSpeechStart = 0
        startTime = nil
    }

    /// 重置 (新一輪對話)
    func reset() {
        state = .listening
        currentLevel = 0
        speechFrameCount = 0
        silenceFrameCount = 0
        speechDuration = 0
        framesSinceSpeechStart = 0
        startTime = nil
    }

    private func transition(to new: State) {
        guard state != new else { return }
        state = new
        if new == .speaking {
            onSpeechStart?()
        }
    }

    private func handleSpeechEnd() {
        // 太短嘅 burst 當 noise
        guard speechDuration >= minSpeechDuration else {
            state = .listening
            speechFrameCount = 0
            silenceFrameCount = 0
            speechDuration = 0
            framesSinceSpeechStart = 0
            startTime = nil
            return
        }
        state = .idle
        onSpeechEnd?()
        // reset for next turn
        speechFrameCount = 0
        silenceFrameCount = 0
        speechDuration = 0
        framesSinceSpeechStart = 0
        startTime = nil
    }
}
