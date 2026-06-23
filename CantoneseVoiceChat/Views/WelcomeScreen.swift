import SwiftUI

/// WelcomeScreen (v0.7.8+) — 開 app 第一個畫面, 仿 launch screen design
/// Auto-dismiss 1 秒後 (iOS launch screen 唔可以收 user input, 唔可以延長 stay time)
struct WelcomeScreen: View {
    let onDismiss: () -> Void
    @State private var scale: CGFloat = 0.85  // 入場 animation 起點

    var body: some View {
        ZStack {
            // Background 跟 launch screen 一致
            Color.accentColor
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // Brand mark (大字「廣」) — 跟 launch screen 一樣
                Text("廣")
                    .font(.system(size: 140, weight: .bold))
                    .foregroundStyle(.white)
                    .scaleEffect(scale)

                // 標題
                Text("廣東話傾偈")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)

                // Tagline
                Text("同 AI 傾偈，學廣東話")
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.85))

                Spacer()
            }
        }
        .onAppear {
            // (v0.7.8+) 1 秒後 auto-dismiss (iOS launch screen 限制, 留長啲 brand 體驗)
            withAnimation(.easeOut(duration: 0.4)) {
                scale = 1.0
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1.0s
                onDismiss()
            }
        }
    }
}

#Preview {
    WelcomeScreen(onDismiss: { print("dismiss") })
}
