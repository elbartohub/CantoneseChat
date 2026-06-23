import SwiftUI

/// Persona chip — 圓形 avatar 風格 (Podcast / Instagram) (v0.7.9+)
///  - 60pt 圓 + persona 主題色 (Models.themeColorHex) pastel 底
///  - 選定嗰個加 3pt accent 邊框凸顯
///  - 名字細字喺圓下面
struct PersonaChip: View {
    let persona: Persona
    let selected: Bool

    private var themeColor: Color { Color(hex: persona.themeColorHex) }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(themeColor.opacity(selected ? 0.32 : 0.18))
                    .frame(width: 60, height: 60)
                Text(persona.emoji)
                    .font(.system(size: 30))
                if selected {
                    Circle()
                        .stroke(Color.accentColor, lineWidth: 3)
                        .frame(width: 66, height: 66)
                }
            }
            // (v0.7.9+) 用 shortName (4 字 fixed) 而唔係 displayName — user feedback
            // 60pt chip 下面 80pt 寬度唔夠放全名, 縮短到 4 字 exactly
            Text(persona.shortName)
                .font(.caption2.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
