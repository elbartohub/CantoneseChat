import SwiftUI
import SwiftData

extension ChatView {
    /// 清空當前 session 嘅所有 message, 但保留 session 本身
    /// (要重開新 chat 就喺 Home 揀 ➕)
    func clearCurrentSession() {
        // 刪 cache files 先, 免得 SwiftData @Relationship cascade delete message 之後 path 拎唔到
        let paths = session.messages.compactMap { $0.ttsCachePath }
        TTSCache.deleteAll(relativePaths: paths)
        for msg in session.messages {
            modelContext.delete(msg)
        }
        // 強制 UI 即時更新
        vm.streamingReply = ""
        vm.textInput = ""
        vm.cancelPipeline()
        do {
            try modelContext.save()
        } catch {
            print("[ChatView] clear failed: \(error.localizedDescription)")
        }
    }
}

struct ChatView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var vm: ChatViewModel
    let session: ChatSession
    @State private var showSettings = false
    @State private var showClearConfirm = false

    init(session: ChatSession) {
        self.session = session
        // 由 env 攞 modelContext 唔直接喺 init 用，所以用 StateObject + onAppear 注入
        let placeholder = ChatViewModel(
            session: session,
            modelContext: try! ModelContainer(
                for: ChatSession.self, Message.self,
                configurations: .init(isStoredInMemoryOnly: true)
            ).mainContext
        )
        _vm = StateObject(wrappedValue: placeholder)
    }

    var body: some View {
        VStack(spacing: 0) {
            // (v0.7.8+) Proxy mode removed, 冇 backend health banner 概念
            scrollArea
            Divider()
            controlBar
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // (v0.7.8+) Persona + date/time 喺 principal (居中) — 取代 simple navigationTitle
            // 騰出 SessionRow 嘅 date, 將 date 放去 chat 入面睇
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text("\(session.persona.emoji) \(session.persona.displayName)")
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(session.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .accessibilityLabel("清空對話")
                }
            }
        }
        .confirmationDialog(
            "清空呢個對話嘅所有訊息？",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) {
                clearCurrentSession()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("呢個動作冇得返轉頭。淨係清而家呢個 persona session 嘅 \(session.messages.count) 條訊息。")
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    // (v0.7.8+) healthBanner + healthBannerContent removed — proxy mode 取消, 冇 backend health 概念

    private var scrollArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    // 正常 order: 舊 top, 新 bottom (chat app 標準)
                    // 用 createdAt explicit sort, 避免 SwiftData @Relationship insertion order 唔穩
                    ForEach(session.messages.sorted { $0.createdAt < $1.createdAt }) { msg in
                        Bubble(message: msg, persona: session.persona) {
                            Task { await vm.replay(message: msg, voice: session.persona.voiceId) }
                        }
                        .id(msg.id)
                    }
                    // 即時 streaming reply — 喺最底
                    if !vm.streamingReply.isEmpty {
                        StreamingBubble(text: vm.streamingReply, persona: session.persona)
                            .id("streaming")
                    }
                    if case .error(let s) = vm.state {
                        ErrorBubble(text: s)
                    }
                }
                .padding()
            }
            .onChange(of: session.messages.count) { _, _ in
                if let last = session.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: vm.streamingReply) { _, _ in
                withAnimation { proxy.scrollTo("streaming", anchor: .bottom) }
            }
        }
    }

    private var controlBar: some View {
        VStack(spacing: 8) {
            statusLabel
            // Text input fallback (always available, even without backend STT)
            HStack(spacing: 8) {
                TextField("或者打一句……", text: Binding(
                    get: { vm.textInput },
                    set: { vm.textInput = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit {
                    Task { await vm.sendTextInput() }
                }
                Button {
                    Task { await vm.sendTextInput() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(vm.textInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal)
            BigMicButton(
                state: vm.state,
                audioLevel: vm.audio.audioLevel
            ) {
                Task {
                    switch vm.state {
                    case .idle, .error, .listening:
                        await vm.startRecording()
                    case .recording:
                        await vm.stopAndSend()
                    case .speaking, .thinking, .transcribing:
                        vm.cancelPipeline()
                    }
                }
            } onLongPress: {
                // Long press = 用 bundled sample m4a 行完整 pipeline
                // (sim 冇 mic, 唔需要真 audio device)
                Task { await vm.runSample() }
            }
            // Mic 永遠可撳: Direct mode 唔需要 backend, Proxy mode 就要
            .opacity(micUsable ? 1 : 0.4)
            .disabled(!micUsable)
            .padding(.bottom, 8)
        }
        .padding(.horizontal)
        .background(.thinMaterial)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch vm.state {
        case .idle, .error:
            EmptyView()
        case .listening:
            Label("等緊你講嘢… (VAD hands-free)", systemImage: "ear")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
        case .recording:
            Label("錄緊音……再撳一下停", systemImage: "waveform")
                .font(.caption)
                .foregroundStyle(.red)
        case .transcribing:
            Label("聽緊你講嘢……", systemImage: "ear")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .thinking:
            Label("諗緊點答你……", systemImage: "brain")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .speaking:
            Label("佢答緊你 (串流播緊)", systemImage: "speaker.wave.2.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    /// Mic 用法提示
    private var micUsageHint: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.caption2)
            Text("撳一下 = 開始錄音, 再撳 = 停 + 送出")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Mic 掣係咪可撳:
    /// (v0.7.8+) Proxy mode removed, 永遠 direct, 永遠可撳 (iOS on-device zh-HK)
    private var micUsable: Bool {
        return true
    }

    // (v0.7.9+) 拎走 speakerChip — user feedback
    // dead code: 從來冇 call 過, displayName + voiceType chip 喺 chat 唔見過
}

// MARK: - Bubble
private struct Bubble: View {
    let message: Message
    let persona: Persona
    let onReplay: () -> Void

    var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser {
                Spacer(minLength: 40)  // 左 Spacer push user bubble 去右
            } else {
                Text(persona.emoji)
                    .font(.title2)
            }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        isUser
                            ? Color.accentColor
                            : Color(.systemGray5)
                    )
                    .foregroundStyle(isUser ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                if !isUser {
                    Button(action: onReplay) {
                        Image(systemName: "play.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            if !isUser {
                Spacer(minLength: 40)  // 右 Spacer push persona bubble 去左
            }
        }
    }
}

private struct ProcessingBubble: View {
    var body: some View {
        HStack {
            ProgressView()
            Text("諗緊……")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct StreamingBubble: View {
    let text: String
    let persona: Persona
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Text(persona.emoji).font(.title2)
            Text(text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.systemGray5))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            ProgressView()
                .scaleEffect(0.6)
        }
    }
}

private struct ErrorBubble: View {
    let text: String
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(showDetails ? text : shortText)
                    .font(.caption)
                Spacer()
                if text.count > 80 {
                    Button(showDetails ? "閂" : "詳情") {
                        showDetails.toggle()
                    }
                    .font(.caption2)
                    .buttonStyle(.borderless)
                }
            }
            // 針對 on-device model 唔支援 嘅情況, 提供一鍵去 Settings
            if text.contains("on-device") || text.contains("Dictation") {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("打開 iOS Settings (去 Keyboard → Dictation)", systemImage: "gearshape")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.accentColor)
                        .clipShape(Capsule())
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(8)
        .background(Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.red)
    }

    private var shortText: String {
        if text.count <= 80 { return text }
        return String(text.prefix(80)) + "…"
    }
}

// MARK: - Big Mic Button
private struct BigMicButton: View {
    let state: ChatViewModel.State
    let audioLevel: Float
    let onTap: () -> Void
    var onLongPress: (() -> Void)? = nil

    var isRecording: Bool {
        if case .recording = state { return true } else { return false }
    }

    var isProcessing: Bool {
        switch state {
        case .thinking, .speaking, .transcribing: return true
        default: return false
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.accentColor.opacity(0.3), lineWidth: 2)
                .frame(width: 80 + CGFloat(audioLevel) * 20,
                       height: 80 + CGFloat(audioLevel) * 20)
                .opacity(isRecording ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: audioLevel)
            Circle()
                .fill(isRecording ? Color.red : Color.accentColor)
                .frame(width: 56, height: 56)
                .shadow(color: .accentColor.opacity(0.4), radius: 6, y: 2)
            if isProcessing {
                ProgressView()
                    .tint(.white)
            } else {
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .contentShape(Circle())
        // Tap = 開始錄 (toggle)
        .onTapGesture {
            print("[Mic] tap fired, isRecording=\(isRecording) isProcessing=\(isProcessing)")
            if !isProcessing {
                onTap()
            }
        }
        .accessibilityLabel(isRecording ? "撳多一下停 + 送出" : "撳開始錄音")
        .accessibilityHint(onLongPress != nil ? "長按 1 秒+ 用 sample audio demo" : "")
        // Long-press 1.0s+ = sample demo (sim 冇 mic 用)
        // 用 highPriorityGesture 確保 long press 唔被 tap 攔截
        .highPriorityGesture(
            LongPressGesture(minimumDuration: 1.0)
                .onEnded { _ in
                    print("[Mic] long press 1s+ fired")
                    if !isProcessing && !isRecording { onLongPress?() }
                }
        )
    }
}
