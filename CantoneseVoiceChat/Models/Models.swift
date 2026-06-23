import SwiftUI
import SwiftData

// MARK: - Persona
// (v0.7.9+) chengyuTeacher 排最先 — user feedback
// 原因: 6 個 persona 入面, 陳sir 嘅語氣最斯文, 用嚟 default persona 比街市阿姐 適合初次見面。
// 改動同時影響: allCases 順序 (HomeView / TtsLabView 嘅 persona chip scroll 順序), Settings default
enum Persona: String, CaseIterable, Codable, Identifiable {
    case chengyuTeacher = "chengyu_teacher"   // 成語老師 (v0.7.9+ 排最先, 之前排最後)
    case chaChaanTang  = "cha_chaan_tang"     // 茶餐廳老闆
    case taxiDriver    = "taxi_driver"        // 的士司機
    case youngster     = "youngster"          // 後生仔
    case aJie          = "a_jie"              // 阿姐
    case aSir          = "a_sir"              // 阿sir

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chaChaanTang:   return "茶記老闆輝哥"
        case .taxiDriver:     return "的士強哥"
        case .youngster:      return "90後阿明"
        case .aJie:           return "街市阿姐"
        case .aSir:           return "阿sir"
        case .chengyuTeacher: return "成語老師陳sir"
        }
    }

    // (v0.7.9+) Short name exactly 4 個中文字 (or 4 char Latin) — 用喺 PersonaChip 圓 avatar 下面
    // user feedback: 60pt chip 唔夠 space 顯示全名, 改 4 字 short version
    // 注意: 已經 ≤4 char 嘅 persona (e.g. 阿sir) 用返自己; 大過 4 char 嘅縮寫
    var shortName: String {
        switch self {
        case .chengyuTeacher: return "成語老師"    // 4 中文字 (v0.7.9+ user feedback, 唔再叫"陳sir")
        case .chaChaanTang:   return "茶記輝哥"    // 4 中文字
        case .taxiDriver:     return "的士強哥"    // 4 中文字
        case .youngster:      return "90後阿明"   // 6 char (2 digit + 4 中文字)
        case .aJie:           return "街市阿姐"    // 4 中文字
        case .aSir:           return "阿sir"       // 已 ≤4
        }
    }

    var emoji: String {
        switch self {
        case .chaChaanTang:   return "🍳"
        case .taxiDriver:     return "🚕"
        case .youngster:      return "🧑‍🎤"
        case .aJie:           return "👵"
        case .aSir:           return "👮"
        case .chengyuTeacher: return "📖"
        }
    }

    // (v0.7.9+) Persona 主題色 — 用嚟 PersonaChip avatar 圓底色 (Podcast / Instagram 風格)
    // 6 個 persona 各自有對應 pastel 顏色, 視覺上更易區分 + 更有 identity
    var themeColorHex: String {
        switch self {
        case .chengyuTeacher: return "#5B8DEF"  // 藍 — 學者/書卷
        case .chaChaanTang:   return "#F08C4A"  // 橙 — 茶記/溫暖
        case .taxiDriver:     return "#E8C547"  // 黃 — 的士/醒目
        case .youngster:      return "#E879A8"  // 粉 — 後生/活力
        case .aJie:           return "#9B6BD4"  // 紫 — 街市/地道
        case .aSir:           return "#4A9B7E"  // 綠 — 阿sir/沉實
        }
    }

    /// 對齊 MiniMax 官方粵語 voice id (要 set language_boost=Chinese,Yue)
    var voiceId: String {
        switch self {
        case .chaChaanTang:   return "Cantonese_podacast_host_1"  // 男, 健談 feel
        case .taxiDriver:     return "Cantonese_podacast_host_1"  // 男, 慢而有味道
        case .youngster:      return "Cantonese_podacast_host_1"  // 男, 偏年輕
        case .aJie:           return "Cantonese_GentleLady"       // 女, 溫柔
        case .aSir:           return "Cantonese_podacast_host_1"  // 男, 沉實
        case .chengyuTeacher: return "Cantonese_podacast_host_1"  // 男, 中年學者 feel
        }
    }

    var systemPrompt: String {
        let lengthCap = "重要: 回答一定要短, 最多 1-2 句, 唔好超過 60 個中文字。唔好列點, 唔好解釋, 唔好重複用戶問嘅嘢。"
        let honorificRule = "用戶性別由聲紋偵測得知 (會喺提示入面講明「聲音係男/女」), 你要根據性別用對應稱呼: 男性 → 「靚仔/先生/老闆」, 女性 → 「靚女/小姐/女士」。"
        switch self {
        case .chaChaanTang:
            return """
            你係香港茶餐廳老闆輝哥，55 歲，講嘢直接、語氣爽。
            成日用「喂」「咩事」「唔該晒」「靚仔」「靚女」。
            唔好用書面語，唔好用北方嗰種尊稱 (nin)。
            鍾意叫人飲凍檸茶，叫人食常餐。
            \(lengthCap)
            \(honorificRule)
            """
        case .taxiDriver:
            return """
            你係香港的士強哥，60 歲，識晒成個香港嘅街道。
            講嘢慢但精，成日用「呢度」「嗰度」「呢條路」「塞車」。
            會主動問去邊度, 提議行車路線。
            \(lengthCap)
            \(honorificRule)
            """
        case .youngster:
            return """
            你係香港 90 後阿明，講嘢快，成日用英文夾雜。
            用「咩」「咁」「囉」「啦」「喎」做句尾。
            可能會講「喂」「GG」「no way」。
            \(lengthCap)
            \(honorificRule)
            """
        case .aJie:
            return """
            你係香港街市阿姐，40 幾歲，講嘢大聲直率。
            成日用「靚姐」「靚仔」「師奶」「阿太」「嗰個」「呢個」。
            鍾意講平嘢、講邊度有折，識叫買餸貼士。
            \(lengthCap)
            \(honorificRule)
            """
        case .aSir:
            return """
            你係香港阿sir，40 歲，紀律部隊出身，講嘢有禮但權威。
            用「先生」「小姐」「請問」「麻煩你」「多謝合作」。
            講嘢清晰、唔講粗口，會叫人小心啲。
            \(lengthCap)
            \(honorificRule)
            """
        case .chengyuTeacher:
            return """
            你係香港中學中文老師陳sir，50 歲，教成語 25 年，講嘢慢而清楚，有耐性。
            成日用「呢個成語呀」「試下記住」「我舉個例」「睇下點用」。
            唔好用書面語，唔好用北方嗰種尊稱 (nin)。用粵語講成語故事，例如「刻舟求劍」「守株待兔」「畫蛇添足」。
            教學風格: 一個成語 + 一句生活例子，唔好長氣。
            \(lengthCap)
            \(honorificRule)
            """
        }
    }
}

// MARK: - ChatSession
@Model
final class ChatSession {
    @Attribute(.unique) var id: UUID
    var title: String
    var personaRaw: String
    var createdAt: Date
    @Relationship(deleteRule: .cascade) var messages: [Message] = []

    /// 用首句 user message 做 display title, truncate 20 字
    /// 冇對話 → "未有對話"
    var displayTitle: String {
        let firstUser = messages.first { $0.role == .user }
        guard let text = firstUser?.text, !text.isEmpty else {
            return "未有對話"
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 20 { return trimmed }
        return String(trimmed.prefix(20)) + "…"
    }

    init(id: UUID = UUID(), title: String, persona: Persona) {
        self.id = id
        self.title = title
        self.personaRaw = persona.rawValue
        self.createdAt = Date()
    }

    var persona: Persona {
        // (v0.7.9+) Fallback 由 .chaChaanTang 改 .chengyuTeacher — 對齊新 default
        Persona(rawValue: personaRaw) ?? .chengyuTeacher
    }
}

// MARK: - Message
@Model
final class Message {
    @Attribute(.unique) var id: UUID
    var roleRaw: String        // "user" | "assistant"
    var text: String
    var createdAt: Date
    /// TTS mp3 file 嘅相對 path (e.g. "tts-cache/<uuid>.mp3"), nil = 未 cache
    var ttsCachePath: String?

    init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.roleRaw = role.rawValue
        self.text = text
        self.createdAt = Date()
    }

    enum Role: String, Codable {
        case user, assistant
    }

    var role: Role { Role(rawValue: roleRaw) ?? .user }
}

// (v0.7.9+) Color(hex:) — 將 6 個 persona 嘅 hex color string 轉做 SwiftUI Color
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b, a: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (r, g, b, a) = ((int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17, 255)
        case 6: // RGB (24-bit)
            (r, g, b, a) = (int >> 16, int >> 8 & 0xFF, int & 0xFF, 255)
        case 8: // ARGB (32-bit)
            (r, g, b, a) = (int >> 16, int >> 8 & 0xFF, int & 0xFF, int >> 24)
        default:
            (r, g, b, a) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
