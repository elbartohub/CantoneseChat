import SwiftUI
import SwiftData

struct SettingsView: View {
    @AppStorage("minimaxApiKey") private var minimaxApiKey: String = ""
    // (v0.7.9+) Default persona 由 chaChaanTang 改 chengyuTeacher — user feedback
    @AppStorage("defaultPersonaRaw") private var defaultPersonaRaw: String = Persona.chengyuTeacher.rawValue
    @AppStorage("speechRate") private var speechRate: Double = 1.0
    @AppStorage("ttsModel") private var ttsModel: String = "speech-2.8-turbo"
    // (v0.7.9+) Default 改 iOS on-device — user feedback (私隱優先, 100% offline)
    // 將來 Voice Clone 會用呢個 channel, 所以保留 Picker UI
    @AppStorage("sttEngine") private var sttEngine: String = "ondevice"
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var showClearConfirm = false
    // (v0.7.9+) Bug fix: 用 shared 唔係 load()
    // 之前用 SpeakerProfile.load() 喺 SettingsView 開個 NEW instance,
    // 但 AudioService 撳 mic 時將 buffer forward 落 SpeakerProfile.shared (另一個 instance).
    // 兩個冇 bridge, Settings 永遠顯示 sampleCount=0 / voiceType=.unknown.
    // 改用 shared 同步 AudioService 嗰邊嘅 update.
    @StateObject private var speaker = SpeakerProfile.shared

    var body: some View {
        NavigationStack {
            Form {
                // (v0.7.8+) Proxy mode removed, 移除 Picker
                Section {
                    Text("需要喺下面填 API key (minimax.io)。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // (v0.7.8+) MiniMax API Key 強制 render — 唔理 UserDefaults apiMode
                // (之前 if apiMode == "direct" condition 導致用戶 UserDefaults 仲係 proxy 時成個 section 唔見)
                Section("MiniMax API Key") {
                    if minimaxApiKey.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("填咗 API key 先用到")
                                .font(.caption.bold())
                                .foregroundStyle(.orange)
                        }
                    }
                    SecureField("MiniMax API key (sk-... or ey...)", text: $minimaxApiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !minimaxApiKey.isEmpty {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Key 已填好")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                        }
                    }
                    // (v0.7.9+) 拎走 security warning text — user feedback
                    // (demo 用戶覺得視覺上太 noise, 接受 demo grade security 風險)
                }

                // (v0.7.8+) Proxy mode 整段唔 render — 用戶 UserDefaults 可能仲有 apiMode=proxy 但我哋完全忽略

                Section("語音辨識 STT") {
                    Picker("STT 引擎", selection: $sttEngine) {
                        // (v0.7.8+) 移除 Backend Whisper (proxy mode 取消)
                        // (v0.7.9+) "🧠 Smart Fallback" 變成 secondary, default 改 ondevice
                        Text("🍎 iOS On-device (100% offline, 預設)").tag("ondevice")
                        Text("🧠 Smart Fallback (on-device → cloud)").tag("auto")
                        Text("☁️ iOS Cloud (Apple server)").tag("cloud")
                    }
                    // (v0.7.9+) 拎走 description + Voice Clone hint — user feedback (visual noise)
                }

                speakerSection

                Section("預設 Persona") {
                    Picker("Persona", selection: $defaultPersonaRaw) {
                        ForEach(Persona.allCases) { p in
                            Text("\(p.emoji) \(p.displayName)").tag(p.rawValue)
                        }
                    }
                }

                Section("TTS (語音合成)") {
                    Picker("模型", selection: $ttsModel) {
                        Text("speech-2.8-turbo (推薦)").tag("speech-2.8-turbo")
                        Text("speech-2.8-hd (高質)").tag("speech-2.8-hd")
                        Text("speech-2.6-turbo (慳)").tag("speech-2.6-turbo")
                        Text("speech-2.6-hd (舊高質)").tag("speech-2.6-hd")
                    }
                    VStack(alignment: .leading) {
                        Text("語速 \(String(format: "%.2fx", speechRate))")
                            .font(.caption)
                        Slider(value: $speechRate, in: 0.5...2.0, step: 0.05) {
                            Text("語速")
                        }
                    }
                }

                Section("對話") {
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label("清空所有對話", systemImage: "trash")
                    }
                }

                // TTS Lab iCloud Export (v0.7.4)
                Section {
                    icloudExportRow
                } header: {
                    Text("TTS Lab — iCloud Export")
                } footer: {
                    Text("Save to iCloud button 將 TTS audio 寫入你揀嘅 folder。folder 一旦揀過即記住，下次自動寫入。要轉 folder 撳「重設」。")
                }

                Section("關於") {
                    // (v0.7.9+) 全部 hard-coded string 過時 (v0.3.0 backend proxy),
                    // 改做現狀: Direct cloud + iOS on-device STT
                    LabeledContent("版本", value: "0.7.9+ (Direct cloud)")
                    LabeledContent("STT", value: "iOS on-device zh-HK / iOS Cloud")
                    LabeledContent("LLM", value: "MiniMax M3 (Direct cloud)")
                    LabeledContent("TTS", value: "MiniMax speech-2.8 (Direct cloud)")
                }
            }
            .navigationTitle("設定")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .confirmationDialog(
                "清空所有對話？",
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button("清空", role: .destructive) {
                    // 全部 cache file 一次過清 (cascade delete 前先 scan)
                    let descriptor = FetchDescriptor<ChatSession>()
                    if let allSessions = try? modelContext.fetch(descriptor) {
                        let paths = allSessions.flatMap { $0.messages.compactMap { $0.ttsCachePath } }
                        TTSCache.deleteAll(relativePaths: paths)
                    }
                    try? modelContext.delete(model: ChatSession.self)
                    try? modelContext.save()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("呢個動作冇得返轉頭。")
            }
            // (v0.7.8+) Bonjour sheet + apiModeDescription removed — proxy mode 取消
        }
    }

    // (v0.7.8+) apiModeDescription removed — proxy mode 取消
    // (v0.7.9+) sttEngineDescription removed — user feedback (UI noise, 拎走)

    // iCloud Export settings row (v0.7.4) — show current picked folder + reset button
    @StateObject private var icloudExporter = ICloudExportService.shared
    @State private var showResetConfirm = false

    @ViewBuilder
    private var icloudExportRow: some View {
        if icloudExporter.hasSavedBookmark {
            // (v0.7.9+) 拎走個 VStack spacing 6 → 4, 拎走 button .padding(.top, 4)
            // user feedback: 上下 padding 太鬆, 收緊
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "icloud")
                        .foregroundStyle(Color.accentColor)
                    Text("已記住 folder")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                }
                Text(icloudExporter.pickedFolderType.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Label("重設 folder", systemImage: "arrow.uturn.backward.circle")
                        .font(.subheadline)
                }
            }
            .confirmationDialog(
                "重設 iCloud folder bookmark?",
                isPresented: $showResetConfirm,
                titleVisibility: .visible
            ) {
                Button("重設", role: .destructive) {
                    icloudExporter.resetFolderBookmark()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("下次撳「Save to iCloud」會彈 picker 重新揀。已寫入嘅 file 唔會受影響。")
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "icloud.slash")
                        .foregroundStyle(.secondary)
                    Text("尚未揀 iCloud folder")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                // (v0.7.5) Hint 提示 user 點 setup bookmark
                // 唔 navigate (cross-stack 複雜), 只係 hint
                Text("去 TTS Lab → 撳「存到 iCloud」揀 iCloud Drive folder, 即自動記住。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // Speaker profile section
    @ViewBuilder
    private var speakerSection: some View {
        Section("你嘅聲線") {
            HStack {
                // (v0.7.9+) Conditional render — unknown voiceType 用 SF Symbol, 其他用 emoji
                if speaker.voiceType == .unknown {
                    Image(systemName: speaker.voiceType.emoji)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                } else {
                    Text(speaker.voiceType.emoji).font(.title2)
                }
                VStack(alignment: .leading) {
                    Text("聲音類型: \(speaker.voiceType.displayName)")
                        .font(.subheadline)
                    if speaker.sampleCount > 0 {
                        Text("平均 pitch: \(Int(speaker.averagePitch))Hz, sample: \(speaker.sampleCount)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("未分析過錄音, 撳幾句 mic 之後自動更新")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            Picker("聲音類型", selection: Binding(
                get: { speaker.voiceType },
                set: { newValue in
                    speaker.voiceType = newValue
                    speaker.save()
                }
            )) {
                ForEach(SpeakerProfile.VoiceType.allCases.filter { $0 != .unknown }) { t in
                    Text("\(t.emoji) \(t.displayName)").tag(t)
                }
            }
            // (v0.7.9+) 拎走 顯示名 TextField — user feedback
            // LLM prompt 已經透過 makeSpeakerContext() 注入 voiceType context
            // displayName 喺 chat 唔見過 (speakerChip dead code), 拎走整個概念
            Text("Persona 會根據你嘅聲線類型調整語氣。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// (v0.7.8+) BonjourPickerSheet removed — proxy mode 取消, 唔再需要 LAN backend auto-detect
/// iOS 17 嘅 ContentUnavailableView 有, 但 iOS 17.0 仲未有, 用 fallback
private struct ContentUnavailableViewCompat: View {
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    SettingsView()
}
