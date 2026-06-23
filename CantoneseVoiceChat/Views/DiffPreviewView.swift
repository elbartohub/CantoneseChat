import SwiftUI

/// DiffPreviewView (v0.7.9+) — 顯示 AI 優化前後對比
/// Used by TTS Lab 「語音/文字」label 旁邊個 AI button
struct DiffPreviewView: View {
    let original: String
    let enhanced: String
    let onAccept: () -> Void
    let onReject: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(Color.accentColor)
                Text("AI 粵語優化").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // Before
            VStack(alignment: .leading, spacing: 4) {
                Label("原本", systemImage: "pencil")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(original)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal, 16)

            // After
            VStack(alignment: .leading, spacing: 4) {
                Label("AI 改寫", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text(enhanced)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal, 16)

            Spacer().frame(height: 4)

            // Actions
            HStack(spacing: 10) {
                Button {
                    onReject()
                } label: {
                    Label("唔覆蓋", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .background(Capsule().fill(Color(.systemGray6)))
                .foregroundStyle(.primary)

                Button {
                    onAccept()
                } label: {
                    Label("覆蓋原文", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .background(Capsule().fill(Color.accentColor))
                .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .background(Color(.systemBackground))
    }
}

#Preview {
    DiffPreviewView(
        original: "今日去咗街市買蘋果",
        enhanced: "今日去咗街市買蘋果喎, 廿蚊斤, 平到爛呀!",
        onAccept: {},
        onReject: {}
    )
}
