import SwiftUI

/// TTS-only 介面 (v0.7) — 用戶輸入文字，照讀出嚟
/// Cache-first: 同一 (persona.voiceId, text) 唔再 call API
struct TtsLabView: View {
    @StateObject private var vm = TtsLabViewModel()
    @FocusState private var textFocused: Bool
    @State private var showingFolderPicker = false
    // (v0.7.9+) AI 粵語優化: diff preview state
    @State private var showingDiffPreview = false
    @State private var pendingEnhancedText: String?  // AI 優化結果, 等 user 採用/取消
    @State private var originalTextForDiff: String?  // 用嚟 DiffPreview 顯示「原本」
    @State private var isEnhancing = false  // button spinner state

    var body: some View {
        VStack(spacing: 0) {
            personaBar
            Divider()
            inputArea
            Spacer()
            controlBar
        }
        .navigationTitle("TTS 練嘢")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: vm.inputText) { _, _ in vm.updateCacheBadge() }
        .onChange(of: vm.selectedPersona) { _, _ in vm.updateCacheBadge() }
    }

    // MARK: - Subviews

    private var personaBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Persona.allCases) { p in
                    PersonaChip(
                        persona: p,
                        selected: p == vm.selectedPersona
                    )
                    .onTapGesture {
                        vm.selectedPersona = p
                    }
                }
                // (v0.7.9+) 加捲動 hint chip「→」— user feedback
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var inputArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("語音/文字")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                // (v0.7.9+) AI 粵語優化 button — 撳一下 LLM 改寫成地道粵語口語
                Button {
                    triggerEnhance()
                } label: {
                    HStack(spacing: 4) {
                        if isEnhancing {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "wand.and.stars")
                                .font(.caption)
                        }
                        Text(isEnhancing ? "AI 優化中…" : "AI 優化")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .disabled(vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isEnhancing)
                Spacer()
                cacheBadge
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            ZStack {
                TextEditor(text: $vm.inputText)
                    .focused($textFocused)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(.systemGray4), lineWidth: 1)
                    )

                if vm.isListening {
                    // 錄音中 overlay — 半透明蓋過 TextEditor
                    recordingOverlay
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 110)  // v0.7.2: 160 → 110 慳 vertical space
        }
    }

    /// Mic button — tap-to-toggle
    /// (v0.7.8+) Mic button — full-width pill button (移到 controlBar 頂部, 「讀出嚟」上面)
    /// 紅色填充 + pulse = 錄音中, 灰底 + mic icon = idle
    /// (v0.7.8+) 用 PressableButtonStyle 加 press feedback
    /// (v0.7.9+) AI 優化 trigger — 撳 button → call vm.enhanceText → 顯示 DiffPreview sheet
    /// (v0.7.9+ rev3) User spec: 先讓用戶選擇是否要覆蓋原文。Sheet 入面有「覆蓋原文」/「唔覆蓋」button
    /// - 「覆蓋原文」→ vm.inputText = enhanced
    /// - 「唔覆蓋」→ 關 sheet, 原本 text 唔變
    private func triggerEnhance() {
        guard !isEnhancing else { return }
        let original = vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return }
        originalTextForDiff = original
        isEnhancing = true
        Task {
            do {
                let enhanced = try await vm.enhanceText()
                pendingEnhancedText = enhanced
                showingDiffPreview = true
            } catch {
                print("[TtsLab] triggerEnhance FAILED: \(error.localizedDescription)")
            }
            isEnhancing = false
        }
    }

    private var micButton: some View {
        Button {
            Task {
                if vm.isListening {
                    await vm.stopListening()
                } else {
                    await vm.startListening()
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: vm.isListening ? "mic.fill" : "mic")
                    .font(.subheadline)
                Text(micButtonLabel)
                    .font(.subheadline.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)  // 統一高度同其他 button
        }
        .buttonStyle(PressableButtonStyle(
            normalBackground: vm.isListening ? Color.red : Color(.systemGray6),
            pressedBackground: vm.isListening ? Color.red.opacity(0.7) : Color(.systemGray4),
            foreground: vm.isListening ? .white : Color.accentColor
        ))
        .disabled(isSpeechBusy)
        .accessibilityLabel(vm.isListening ? "停止錄音" : "語音輸入")
    }

    /// Mic button label 跟 state 變
    private var micButtonLabel: String {
        switch vm.speechState {
        case .requestingPermission: return "請求權限中…"
        case .transcribing:         return "語音辨識中…"
        default:
            return vm.isListening ? "錄音中… 撳停" : "語音輸入"
        }
    }

    private var recordingOverlay: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .opacity(0.9)
            Text("錄音中… 撳 mic 停")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(.red.opacity(0.85))
        )
    }

    private var isSpeechBusy: Bool {
        switch vm.speechState {
        case .requestingPermission, .transcribing: return true
        default: return false
        }
    }

    private var cacheBadge: some View {
        Group {
            switch vm.cacheState {
            case .unknown:
                EmptyView()
            case .miss:
                Label("將會 fetch", systemImage: "icloud.and.arrow.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .hit:
                Label("已 cache", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }

    private var controlBar: some View {
        VStack(spacing: 10) {
            // Status / error message
            statusLabel

            // (v0.7.8+) Mic button 移到 controlBar 頂部 (獨立 row)
            // 視覺流程: 錄音 → 讀出嚟, 由上至下
            micButton
                .frame(maxWidth: .infinity)

            // Row 1: 主要按鈕 (full width)
            // (v0.7.8+) 用 custom Capsule background 而唔係 .borderedProminent,
            // 因為 borderedProminent 內部 padding 跟 bordered 唔同, 高度唔一致
            SpeakButton(
                title: vm.state == .synthesizing ? "處理中…" : "讀出嚟",
                systemImage: "speaker.wave.2.fill",
                isDisabled: vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy
            ) {
                Task { await vm.speak() }
            }

            // Row 2: 次要掣並排 (再聽一次 + 存到 iCloud)
            HStack(spacing: 10) {
                // 重聽按鈕
                SecondaryActionButton(
                    title: "再聽一次",
                    systemImage: "arrow.counterclockwise",
                    isDisabled: vm.lastPlayedCachePath == nil || isBusy
                ) {
                    Task { await vm.replayLast() }
                }

                // Save to iCloud button (v0.7.3)
                SecondaryActionButton(
                    title: icloudButtonLabel,
                    systemImage: "icloud.and.arrow.up",
                    isDisabled: vm.lastPlayedCachePath == nil || isBusy || isICloudExporting
                ) {
                    Task {
                        let triggered = await vm.exportLastAudioToICloud()
                        if !triggered {
                            // 冇 saved folder → 彈 picker
                            showingFolderPicker = true
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.systemBackground))
        .sheet(isPresented: $showingFolderPicker) {
            FolderPicker(
                onPick: { url in
                    showingFolderPicker = false
                    vm.handlePickedFolderAndExport(url)
                },
                onCancel: {
                    showingFolderPicker = false
                }
            )
        }
        // (v0.7.9+ rev3) AI 廣東話優化 Diff preview sheet
        // 撳 sheet 入面嘅「覆蓋原文」先 cover textarea, 「唔覆蓋」keep 原 text
        .sheet(isPresented: $showingDiffPreview) {
            if let pending = pendingEnhancedText, let original = originalTextForDiff {
                DiffPreviewView(
                    original: original,
                    enhanced: pending,
                    onAccept: {
                        vm.inputText = pending  // 覆蓋 textarea
                        showingDiffPreview = false
                        pendingEnhancedText = nil
                        originalTextForDiff = nil
                    },
                    onReject: {
                        showingDiffPreview = false
                        pendingEnhancedText = nil
                        originalTextForDiff = nil
                    }
                )
                .presentationDetents([.fraction(0.45)])
            }
        }
    }

    /// iCloud button label 跟 state 變
    private var icloudButtonLabel: String {
        switch vm.icloudExporter.state {
        case .exporting: return "寫入中…"
        case .success:   return "已存!"
        default:         return "存到 iCloud"
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        // Speech error / status 優先顯示 (TTS 之上)
        switch vm.speechState {
        case .error(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .multilineTextAlignment(.leading)
        case .transcribing:
            Label("語音辨識中…", systemImage: "waveform.and.mic")
                .font(.caption)
                .foregroundStyle(.secondary)
        default:
            switch vm.state {
            case .playing:
                Label("播放中…", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .synthesizing:
                Label("TTS 處理中…", systemImage: "ellipsis.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .enhancing:
                Label("AI 優化中…", systemImage: "wand.and.stars")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            case .error(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.leading)
            case .idle:
                EmptyView()
            }
        }
    }

    private var isBusy: Bool {
        switch vm.state {
        case .synthesizing, .playing, .enhancing: return true
        default: return false
        }
    }

    /// iCloud export 在跑 (v0.7.5) — disable Save button 防 race condition
    private var isICloudExporting: Bool {
        if case .exporting = vm.icloudExporter.state { return true }
        return false
    }
}

// MARK: - Unified control bar buttons (v0.7.8+)
// 全部用 custom Capsule + 固定 height 48pt, 避免 SwiftUI default button style 高度不一致

/// (v0.7.8+) 自定 ButtonStyle — 撳住時 background 變深色, 放手變返淺色
/// 用法: .buttonStyle(PressableButtonStyle(normalBg: ..., pressedBg: ..., foreground: ...))
private struct PressableButtonStyle: ButtonStyle {
    let normalBackground: Color
    let pressedBackground: Color
    let foreground: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Capsule().fill(configuration.isPressed ? pressedBackground : normalBackground))
            .foregroundStyle(foreground)
    }
}

/// Primary action button (e.g. 讀出嚟) — accent fill, white text
private struct SpeakButton: View {
    let title: String
    let systemImage: String
    let isDisabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
        }
        .buttonStyle(PressableButtonStyle(
            normalBackground: Color.accentColor,
            pressedBackground: Color.accentColor.opacity(0.7),
            foreground: .white
        ))
        .opacity(isDisabled ? 0.5 : 1.0)
        .disabled(isDisabled)
    }
}

/// Secondary action button (e.g. 再聽一次 / 存到 iCloud) — gray fill, primary text
private struct SecondaryActionButton: View {
    let title: String
    let systemImage: String
    let isDisabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
        }
        .buttonStyle(PressableButtonStyle(
            normalBackground: Color(.systemGray6),
            pressedBackground: Color(.systemGray4),
            foreground: .primary
        ))
        .opacity(isDisabled ? 0.5 : 1.0)
        .disabled(isDisabled)
    }
}

#Preview {
    NavigationStack {
        TtsLabView()
    }
}
