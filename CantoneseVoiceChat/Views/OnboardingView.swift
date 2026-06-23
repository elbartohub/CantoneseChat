import SwiftUI

struct OnboardingView: View {
    @AppStorage("didOnboard") private var didOnboard: Bool = false
    @AppStorage("apiKey") private var apiKey: String = ""
    @State private var keyInput: String = ""
    @State private var step: Int = 0  // 0: welcome, 1: api key

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.8), Color.orange.opacity(0.6)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()
                if step == 0 {
                    welcomeBlock
                } else {
                    apiKeyBlock
                }
                Spacer()
            }
            .padding()
        }
    }

    private var welcomeBlock: some View {
        VStack(spacing: 20) {
            Text("🗣️")
                .font(.system(size: 80))
            Text("用廣東話傾偈")
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
            Text("揀個 persona，撳住個咪講嘢就得。\nMiniMax M3 全程用粵語同你傾。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal)
            Button {
                withAnimation { step = 1 }
            } label: {
                Text("開始")
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 30)
            .padding(.top, 10)
        }
    }

    private var apiKeyBlock: some View {
        VStack(spacing: 20) {
            Text("🔑")
                .font(.system(size: 60))
            Text("輸入 MiniMax API Key")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Text("用嚟對接 MiniMax M3。Key 只儲喺本機。")
                .multilineTextAlignment(.center)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal)
            SecureField("sk-...", text: $keyInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding()
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 30)
            Button {
                apiKey = keyInput
                didOnboard = true
            } label: {
                Text("開始傾偈")
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 30)
            .disabled(keyInput.isEmpty)
            .opacity(keyInput.isEmpty ? 0.5 : 1)
        }
    }
}

#Preview {
    OnboardingView()
}
