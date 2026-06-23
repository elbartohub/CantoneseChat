import Foundation

/// 簡單嘅 TTS 串行 queue — 一句播完先播下一句
/// 用 actor 確保 thread-safe, 唔阻塞 main actor
actor TTSSerialQueue {
    private var queue: [() async -> Void] = []
    private var running: Bool = false

    func enqueue(_ work: @escaping () async -> Void) {
        queue.append(work)
        print("[TTS-Q] enqueue, queue=\(queue.count)")
        Task { await processNext() }
    }

    func drain() async {
        // poll 到 queue 清 + running = false
        for _ in 0..<600 {  // max 60s
            if !running && queue.isEmpty { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func processNext() async {
        guard !running, let next = queue.first else { return }
        running = true
        queue.removeFirst()
        print("[TTS-Q] start, remaining=\(queue.count)")
        await next()
        print("[TTS-Q] done")
        running = false
        if !queue.isEmpty {
            await processNext()
        }
    }
}
