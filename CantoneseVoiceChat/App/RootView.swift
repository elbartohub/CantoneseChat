import SwiftUI

struct RootView: View {
    @AppStorage("didOnboard") private var didOnboard: Bool = false
    @AppStorage("apiKey") private var apiKey: String = ""
    // (v0.7.8+) Welcome screen gate — 仿 launch screen 設計, 1 秒後 auto-dismiss
    // (iOS 限制 launch screen 唔可以收 input + 唔可以延長 stay time, 所以用 app 內 welcome screen 延長 1s)
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome: Bool = false
    @State private var showWelcome = true

    var body: some View {
        Group {
            // (v0.7.8+) Welcome screen 第一個出現 (iOS launch screen dismiss 後)
            // 用 local state showWelcome 控制, 一 dismiss 之後就唔再出現
            if showWelcome && !hasSeenWelcome {
                WelcomeScreen {
                    hasSeenWelcome = true
                    showWelcome = false
                }
            } else if didOnboard && !apiKey.isEmpty {
                HomeView()
            } else {
                OnboardingView()
            }
        }
    }
}

#Preview {
    RootView()
}
