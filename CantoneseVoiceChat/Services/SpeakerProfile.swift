import Foundation
import AVFoundation

/// 用戶聲線 profile — 簡單 audio fingerprint
///
/// 唔做真 speaker recognition (要 CoreML/聲紋 embedding), 用啟發式:
///   - 平均 pitch (基頻) - 男/女/童
///   - 平均 energy (RMS) - 講嘢大聲定細聲
///   - 講嘢速度 (frames per second onsets)
///
/// 用途:
///   1. Settings 揀 "你係咩人" (小朋友/後生仔/中年人/長者) → 影響 persona greeting
///   2. 之後用聲紋 embedding 升級做真 speaker ID
// (v0.7.9+) @MainActor 已經喺原 code 標 (避免 audio thread 改 @Published
// 唔 re-render). AudioService 撳 mic tap callback 已經用 Task { @MainActor in }
// wrap 個 update() call.
final class SpeakerProfile: ObservableObject, Codable {

    enum VoiceType: String, CaseIterable, Identifiable, Codable {
        case child = "child"        // 小朋友 (高 pitch)
        case youngFemale = "young_f"  // 後生女
        case youngMale = "young_m"    // 後生仔
        case middleFemale = "mid_f"  // 中年女
        case middleMale = "mid_m"    // 中年男
        case seniorFemale = "senior_f"  // 長者女
        case seniorMale = "senior_m"    // 長者男
        case unknown = "unknown"

        var id: String { rawValue }

        /// 從 voice type 推斷 gender
        var gender: Gender {
            switch self {
            case .child, .unknown: return .unknown
            case .youngFemale, .middleFemale, .seniorFemale: return .female
            case .youngMale, .middleMale, .seniorMale: return .male
            }
        }

        /// 從 voice type 推斷 age group
        var ageGroup: AgeGroup {
            switch self {
            case .child: return .child
            case .youngFemale, .youngMale: return .young
            case .middleFemale, .middleMale: return .middle
            case .seniorFemale, .seniorMale: return .senior
            case .unknown: return .unknown
            }
        }

        enum Gender: String, Codable { case male, female, unknown }
        enum AgeGroup: String, Codable { case child, young, middle, senior, unknown }

        var displayName: String {
            switch self {
            case .child: return "小朋友"
            case .youngFemale: return "後生女"
            case .youngMale: return "後生仔"
            case .middleFemale: return "中年女"
            case .middleMale: return "中年男"
            case .seniorFemale: return "長者女"
            case .seniorMale: return "長者男"
            // (v0.7.9+) "未辨識" → "未設定" — user feedback (語意更清楚, 表示 user 仲未做 setting)
            case .unknown: return "未設定"
            }
        }

        var emoji: String {
            switch self {
            case .child: return "🧒"
            case .youngFemale: return "👩"
            case .youngMale: return "👨"
            case .middleFemale: return "👩‍💼"
            case .middleMale: return "👨‍💼"
            case .seniorFemale: return "👵"
            case .seniorMale: return "👴"
            // (v0.7.9+) 改用 SF Symbol "person.wave.2.fill" — user feedback
            // 表示「未辨識但係分析緊」(人 + 音波), 比 ❓ 語意更清楚
            case .unknown: return "person.wave.2.fill"
            }
        }

    /// 預期 pitch range (Hz), 用嚟做 quick fingerprint
    var pitchRange: ClosedRange<Float> {
            switch self {
            case .child: return 220...450
            case .youngFemale: return 165...255
            case .youngMale: return 85...180
            case .middleFemale: return 150...230
            case .middleMale: return 75...165
            case .seniorFemale: return 140...220
            case .seniorMale: return 70...160
            case .unknown: return 0...1000
            }
        }
    }

    @Published var voiceType: VoiceType = .unknown
    // (v0.7.9+) 拎走 @Published var displayName: String = "我" — user feedback
    // LLM prompt 已經有 makeSpeakerContext() 注入 voiceType context
    // user displayName 喺 chat 從來冇 render 過 (speakerChip dead code)
    @Published var averagePitch: Float = 0
    @Published var averageEnergy: Float = 0
    @Published var sampleCount: Int = 0
    /// 儲存最近 pitch samples for median calculation
    private var recentPitches: [Float] = []
    private let recentPitchLimit = 10
    /// 至少 5 個 sample 先 confident classify, 之後用 median 抵抗 outlier
    private let minSamplesForClassification = 5

    static let shared = SpeakerProfile()

    /// 從音訊 file 估算 pitch (autocorrelation method, 簡化)
    /// 對 mono PCM 16kHz/16-bit 比較 work
    /// 即時接受 audio buffer 同 RMS level, 跑聲紋分析
    /// 喺 AVAudioEngine tap 入面 fire, 主 thread call
    /// 一個 buffer → N 個 sub-window pitch → median → classify
    func update(level: Float, audioBuffer: AVAudioPCMBuffer) {
        guard let chData = audioBuffer.floatChannelData?[0] else { return }
        let frames = Int(audioBuffer.frameLength)
        guard frames > 100 else { return }
        let sampleRate = Float(audioBuffer.format.sampleRate)

        // 跳過 ambient noise (energy 過低)
        var sumSquares: Float = 0
        for i in 0..<frames { sumSquares += chData[i] * chData[i] }
        let energy = sqrt(sumSquares / Float(frames))
        guard energy > 0.02 else { return }

        // ⚠️ 重要: iPhone AVAudioEngine 個 input tap 個 sample rate 通常係 44.1kHz 或 48kHz,
        // 唔係 16kHz. 對於 pitch detection, 16kHz 標準化先穩定.
        // iPhone 16kHz minLag = 32, maxLag = 267 (60-500Hz)
        // iPhone 48kHz minLag = 96, maxLag = 800 — 第一個 peak 通常係 2nd harmonic
        // 解決: 將 buffer downsample 落 16kHz 之前做 autocorrelation
        let targetSr: Float = 16000
        let workSr: Float = sampleRate > targetSr * 1.5 ? targetSr : sampleRate
        let workFrames: Int
        let workChData: UnsafeMutablePointer<Float>
        var ownedData: [Float]? = nil
        if sampleRate > targetSr * 1.5 {
            let downsampleFactor = Int(sampleRate / targetSr)
            let downLen = frames / downsampleFactor
            // 用 mean filter 做抗混疊降採樣
            var ds = [Float](repeating: 0, count: downLen)
            for i in 0..<downLen {
                var sum: Float = 0
                for j in 0..<downsampleFactor {
                    sum += chData[i * downsampleFactor + j]
                }
                ds[i] = sum / Float(downsampleFactor)
            }
            ownedData = ds
            workChData = ds.withUnsafeMutableBufferPointer { $0.baseAddress! }
            workFrames = downLen
        } else {
            workChData = UnsafeMutablePointer(mutating: chData)
            workFrames = frames
        }

        // 分 buffer 為 N 個 sub-windows (32ms @ 16kHz, 50% overlap)
        let windowSize = 512
        let hopSize = 256
        var pitches: [Float] = []
        var start = 0
        while start + windowSize <= workFrames {
            let window = UnsafeBufferPointer(start: workChData.advanced(by: start), count: windowSize)
            let p = estimatePitch(window.baseAddress!, frames: windowSize, sampleRate: workSr)
            if p > 60, p < 500 {
                pitches.append(p)
            }
            start += hopSize
        }
        // 如果 sub-windows 全部都冇 valid pitch, skip
        guard !pitches.isEmpty else { return }

        let pitch = SpeakerProfile.median(pitches)

        // 用 median(今次 sub-windows) + median(過去 samples 嘅 5 個) 抗 noise
        recentPitches.append(pitch)
        if recentPitches.count > recentPitchLimit {
            recentPitches.removeFirst()
        }
        let finalPitch = SpeakerProfile.median(recentPitches)

        averagePitch = finalPitch
        averageEnergy = energy
        sampleCount += 1

        let newType = classifyVoice(pitch: finalPitch)
        if newType != voiceType {
            print("[SpeakerProfile] voiceType changed: \(voiceType) → \(newType) (gender=\(newType.gender), ageGroup=\(newType.ageGroup)) at sample \(sampleCount), pitch=\(finalPitch)Hz (raw=\(pitch)Hz, subW=\(pitches.count))")
        }
        voiceType = newType
    }

    func analyzeAudioFile(at url: URL) async {
        do {
            let file = try AVAudioFile(forReading: url)
            let frameCount = AVAudioFrameCount(file.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else { return }
            try file.read(into: buffer)
            update(level: 0, audioBuffer: buffer)
        } catch {
            print("[SpeakerProfile] analyze failed: \(error.localizedDescription)")
        }
    }

    /// Estimate F0 fundamental frequency via autocorrelation
    /// ⚠️ 男聲 F0 (~95-130Hz @ 16kHz → lag 123-168) 經常被誤認做 2nd harmonic (~190-260Hz → lag 62-84),
    /// 因為 autocorrelation 個 first peak 通常係 2nd harmonic 較強.
    /// Fix: 掃 lag range, 同時 check lag 同 2x lag, 3x lag 嘅 correlation,
    /// 如果 high lag (lower freq) 個 correlation 都高, 用低頻做 fundamental.
    private func estimatePitch(_ data: UnsafePointer<Float>, frames: Int, sampleRate: Float) -> Float {
        // 60-500 Hz, 對應 16kHz sample rate: lag 32 - 267 samples
        let minLag = Int(sampleRate / 500)
        let maxLag = Int(sampleRate / 60)
        let lagRange = max(1, min(maxLag, frames / 2) - minLag)
        guard lagRange > 0 else { return 0 }

        // 計 autocorrelation 一次, 拎 lag → corr 個 dict
        var corrByLag: [Int: Float] = [:]
        for lag in minLag..<(minLag + lagRange) {
            var corr: Float = 0
            let n = frames - lag
            for i in 0..<n {
                corr += data[i] * data[i + lag]
            }
            corrByLag[lag] = corr
        }

        // 搵最大 correlation 嘅 lag (first peak)
        var bestLag = 0
        var bestCorr: Float = 0
        for (lag, corr) in corrByLag {
            if corr > bestCorr {
                bestCorr = corr
                bestLag = lag
            }
        }
        guard bestLag > 0, bestCorr > 0.001 else { return 0 }

        // Octave correction: 如果 bestLag 嘅 2x (i.e. lower frequency) 個 correlation ≥ 0.7 * bestCorr,
        // 即係 fundamental 真係喺 bestLag * 2 (即係 2x lag = half frequency)
        let doubleLag = bestLag * 2
        if doubleLag <= maxLag, let doubleCorr = corrByLag[doubleLag] {
            if doubleCorr >= 0.7 * bestCorr {
                return sampleRate / Float(doubleLag)  // 真係 lower octave
            }
        }
        let tripleLag = bestLag * 3
        if tripleLag <= maxLag, let tripleCorr = corrByLag[tripleLag] {
            if tripleCorr >= 0.5 * bestCorr {
                return sampleRate / Float(tripleLag)
            }
        }
        return sampleRate / Float(bestLag)
    }

    func classifyVoice(pitch: Float) -> VoiceType {
        if pitch <= 0 { return .unknown }
        // 男性優先 heuristic: 個 autocorrelation estimate 對男性 voice 容易偏高 30-50Hz,
        // 所以 male range 收緊, female range 擴張避免 male 被誤判做 female
        // < 165Hz → 男 (any age)
        // 165-200Hz → 男 / 女 都有可能, 用緊返 median(過去 samples) 決定
        // > 200Hz → 女 / child
        if pitch < 165 { return .middleMale }
        if pitch < 200 { return .seniorMale }  // 男中位偏低
        if pitch < 250 { return .youngFemale }  // 女
        // > 250Hz
        let femalePitch = pitch
        if femalePitch < 270 { return .youngFemale }
        if femalePitch < 350 { return .middleFemale }
        return .child
    }

    /// 計算 median (for robust classification)
    static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let n = sorted.count
        if n % 2 == 0 {
            return (sorted[n/2 - 1] + sorted[n/2]) / 2
        } else {
            return sorted[n/2]
        }
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        // (v0.7.9+) 拎走 displayName — user feedback
        case voiceType, averagePitch, averageEnergy, sampleCount
    }

    init() {}

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        voiceType = try c.decode(VoiceType.self, forKey: .voiceType)
        averagePitch = try c.decode(Float.self, forKey: .averagePitch)
        averageEnergy = try c.decode(Float.self, forKey: .averageEnergy)
        sampleCount = try c.decode(Int.self, forKey: .sampleCount)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(voiceType, forKey: .voiceType)
        try c.encode(averagePitch, forKey: .averagePitch)
        try c.encode(averageEnergy, forKey: .averageEnergy)
        try c.encode(sampleCount, forKey: .sampleCount)
    }

    /// 持久化 (UserDefaults JSON)
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "speakerProfile")
        }
    }

    static func load() -> SpeakerProfile {
        if let data = UserDefaults.standard.data(forKey: "speakerProfile"),
           let profile = try? JSONDecoder().decode(SpeakerProfile.self, from: data) {
            return profile
        }
        return SpeakerProfile()
    }
}
