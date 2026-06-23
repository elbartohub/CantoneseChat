import Foundation
import AVFoundation
import Combine

/// Streaming MP3 player — 一邊收 chunk 一邊播
/// 原理：每個 chunk 累積落一個 global buffer, 用 AVAudioConverter 解碼成 PCM,
///       scheduleBuffer 推落 playerNode 連續播, finish() 後 push 最後嘅 data
/// 避免 scheduleFile 嘅 mp3 header 殘留問題
@MainActor
final class StreamingAudioPlayer: ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var bufferedMs: Int = 0
    @Published var lastError: String?

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var format: AVAudioFormat?

    // 累積 raw mp3 bytes
    private var accumulated: Data = Data()
    private let lock = NSLock()
    private var hasScheduled: Bool = false
    private var totalReceived: Int = 0
    private var finished: Bool = false

    private var didAttach: Bool = false

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
        if !didAttach {
            engine.attach(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
            didAttach = true
        }
        if !engine.isRunning {
            try engine.start()
        }
        playerNode.play()
        isPlaying = true
        accumulated = Data()
        hasScheduled = false
        totalReceived = 0
        finished = false
    }

    /// 新 sentence 開始 — 清 playerNode 內部 schedule queue, 唔重啟 engine (避免 duplicate attach)
    func reset() {
        playerNode.stop()
        lock.lock()
        accumulated = Data()
        lock.unlock()
        hasScheduled = false
        totalReceived = 0
        finished = false
        isPlaying = false
    }

    /// 接受 mp3 chunk, 累積
    func append(chunk: Data) {
        lock.lock()
        accumulated.append(chunk)
        totalReceived += chunk.count
        lock.unlock()
    }

    /// 標記 stream 結束, 將累積嘅 mp3 解碼成 PCM buffer 一次過 schedule
    func finish() {
        finished = true
        scheduleAccumulated()
    }

    private func scheduleAccumulated() {
        lock.lock()
        let data = accumulated
        accumulated = Data()
        lock.unlock()

        guard !data.isEmpty else { return }
        guard hasScheduled == false else {
            // 已 schedule 過, 將剩餘 data 連同 next start 嘅 chunks 一齊 schedule
            lock.lock()
            accumulated = data + accumulated
            lock.unlock()
            return
        }

        do {
            // Write 落 temp file, 用 AVAudioFile decode
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("stream-\(UUID().uuidString).mp3")
            try data.write(to: tmp)
            let file = try AVAudioFile(forReading: tmp)
            if format == nil { format = file.processingFormat }
            print("[Player] scheduleFile \(data.count)B")
            playerNode.scheduleFile(file, at: nil) { [weak self] in
                try? FileManager.default.removeItem(at: tmp)
                Task { @MainActor in
                    guard let self else { return }
                    self.isPlaying = false
                }
            }
            hasScheduled = true
        } catch {
            lastError = "decode failed: \(error.localizedDescription)"
            print("[Player] decode failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        playerNode.stop()
        engine.stop()
        isPlaying = false
        lock.lock()
        accumulated = Data()
        lock.unlock()
    }
}
