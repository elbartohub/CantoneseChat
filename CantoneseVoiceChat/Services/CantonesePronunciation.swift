import Foundation

/// 粵語 pronunciation override dictionary
/// 喺 TTS synthesize 之前 substitute, 確保 TTS 用對嘅粵音.
/// 順便 expose 比 LLM system prompt, 教 LLM 用同一個粵音 spelling.
@MainActor
final class CantonesePronunciation {
    static let shared = CantonesePronunciation()

    /// 「原字>替代字」嘅 ordered pairs (longest first for greedy match)
    private var pairs: [(from: String, to: String)] = []

    /// Same as pairs but typed for inference
    private typealias OverridePair = (from: String, to: String)

    private init() {
        loadDefaults()
        loadBundleOverrides()
        // 只 log 一次 (init 觸發, 但不論幾時)
        print("[CantonesePronunciation] ready with \(pairs.count) overrides")
    }

    private func loadDefaults() {
        pairs = []
        // Hardcoded 常用粵音 override
        let defaults: [OverridePair] = [
            ("35 美元", "三十五蚊"),
            ("三十五", "三十五蚊"),
            ("1 美元", "一蚊"),
            ("$35", "三十五蚊"),
            ("$1", "一蚊"),
            ("HK$35", "港紙三十五蚊"),
            ("HKD", "港紙"),
            ("港幣", "港紙"),
            ("美元", "蚊"),
            ("dollars", "蚊"),
            ("dollar", "蚊"),
        ]
        pairs.append(contentsOf: defaults)
    }

    /// Load from bundle resource `pronunciation_overrides.txt`
    /// File format: "原字>替代字" 一行一個
    func loadBundleOverrides() {
        guard let url = Bundle.main.url(forResource: "pronunciation_overrides", withExtension: "txt") else { return }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("//") else { continue }
                let parts = trimmed.components(separatedBy: ">")
                guard parts.count == 2 else { continue }
                let from = parts[0].trimmingCharacters(in: .whitespaces)
                let to = parts[1].trimmingCharacters(in: .whitespaces)
                if !from.isEmpty, !to.isEmpty {
                    // 移除舊 entry, 加新 (新嘅排前面, 優先 match)
                    pairs.removeAll { $0.from == from }
                    pairs.insert((from, to), at: 0)
                }
            }
            // 長嘅排前面 (greedy match)
            pairs.sort { $0.from.count > $1.from.count }
            // Avoid 重複 log
            // (loadBundleOverrides 可能被 multi-instance init 觸發, 唔 log)
        } catch {
            print("[CantonesePronunciation] failed to load: \(error.localizedDescription)")
        }
    }

    /// Apply all overrides to text
    /// e.g. "我有 35 美元" → "我有 三十五蚊"
    func apply(to text: String) -> String {
        var result = text
        for (from, to) in pairs {
            result = result.replacingOccurrences(of: from, with: to)
        }
        return result
    }

    /// Get all overrides as dictionary (for LLM system prompt)
    /// e.g. "5 美元", "三十五蚊"
    func overrideSummary() -> String {
        return pairs.prefix(10).map { "「\($0.from)」→讀「\($0.to)」" }.joined(separator: ", ")
    }
}
