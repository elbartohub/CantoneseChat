import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ChatSession.createdAt, order: .reverse) private var sessions: [ChatSession]
    // (v0.7.9+) Default persona 由 chaChaanTang 改 chengyuTeacher — user feedback
    // 陳sir 語氣最斯文, 適合初次見面。注意: 已有 UserDefaults value 嘅 user 唔受影響 (?? fallback 邏輯)
    @AppStorage("defaultPersonaRaw") private var defaultPersonaRaw: String = Persona.chengyuTeacher.rawValue
    @State private var showSettings = false
    @State private var newSession: ChatSession?
    @State private var showDemoEntry: Bool = true

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                List {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(Persona.allCases) { p in
                                    PersonaChip(persona: p, selected: p.rawValue == defaultPersonaRaw)
                                        .onTapGesture {
                                            defaultPersonaRaw = p.rawValue
                                        }
                                }
                                // (v0.7.9+) 加捲動 hint chip「→」— user feedback
                                // 提示用戶有更多 persona 可以 scroll 過去
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 4)
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                    .listSectionSpacing(.custom(0))  // v0.7.2: 完全歸零 section spacing

                    // v0.4: 一鍵 Demo 隱藏 (右下角 + button 已可以新 session)
                    if false && showDemoEntry {
                        Section {
                            DemoEntryCard(action: startDemo)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                        }
                    }

                    Section {
                        if sessions.isEmpty {
                            ContentUnavailableView(
                                "未有對話",
                                systemImage: "mic.slash",
                                description: Text("撳下面粒掣開始第一個傾偈")
                            )
                            .listRowBackground(Color.clear)
                        } else {
                            ForEach(sessions) { s in
                                NavigationLink {
                                    ChatView(session: s)
                                } label: {
                                    SessionRow(session: s)
                                }
                            }
                            .onDelete(perform: deleteSessions)
                        }
                    } header: {
                        SectionHeaderLabel("對話", systemImage: "bubble.left.and.bubble.right.fill")
                    }
                    .listSectionSpacing(.custom(8))

                    // v0.7: TTS Lab tile — 純文字→TTS, 唔需要 backend chat
                    Section {
                        NavigationLink {
                            TtsLabView()
                        } label: {
                            HStack(spacing: 14) {
                                ZStack {
                                    Circle()
                                        .fill(Color.accentColor.opacity(0.15))
                                        .frame(width: 44, height: 44)
                                    Image(systemName: "waveform.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(Color.accentColor)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("TTS 練嘢")
                                        .font(.headline)
                                    Text("輸入粵語文字，照讀出嚟。可揀 6 個 persona 嘅聲。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 4)
                        }
                    } header: {
                        SectionHeaderLabel("工具", systemImage: "wrench.and.screwdriver.fill")
                    }
                    .listSectionSpacing(.custom(8))
                }
                .listStyle(.insetGrouped)
                // (v0.7.9+) 拎走 List 頂部預設 margin — user feedback
                // 主題「廣東話傾偈」下面嘅空白太多, contentMargins(.top, 0) 拎走 List 預設 ~16pt 頂部 padding
                .contentMargins(.top, 0, for: .scrollContent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        // (v0.7.7+) Custom brand title — rounded design + accent gradient
                        // 比 system .largeTitle 更有 personality
                        Text("廣東話傾偈")
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }

                Button {
                    let persona = Persona(rawValue: defaultPersonaRaw) ?? .chengyuTeacher
                    let s = ChatSession(title: "新對話", persona: persona)
                    modelContext.insert(s)
                    try? modelContext.save()
                    newSession = s
                } label: {
                    Image(systemName: "plus")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Color.accentColor)
                        .clipShape(Circle())
                        .shadow(radius: 6, y: 3)
                }
                .padding(20)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .navigationDestination(item: $newSession) { s in
                ChatView(session: s)
            }
        }
    }

    private func startDemo() {
        let persona = Persona(rawValue: defaultPersonaRaw) ?? .chengyuTeacher
        let s = ChatSession(title: "一鍵 Demo · \(persona.displayName)", persona: persona)
        modelContext.insert(s)
        try? modelContext.save()
        showDemoEntry = false
        newSession = s
    }

    private func deleteSessions(at offsets: IndexSet) {
        // 刪 cache files 先 (拎 messages 嘅 path, 再 cascade delete session)
        for i in offsets {
            let paths = sessions[i].messages.compactMap { $0.ttsCachePath }
            TTSCache.deleteAll(relativePaths: paths)
        }
        for i in offsets {
            modelContext.delete(sessions[i])
        }
        try? modelContext.save()
    }
}

private struct SessionRow: View {
    let session: ChatSession
    var body: some View {
        HStack(spacing: 12) {
            Text(session.persona.emoji)
                .font(.title)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle)
                    .font(.headline)
                    .lineLimit(2)  // (v0.7.8+) 騰出右邊 date 位置後, title 可 wrap 2 行
                Text(session.persona.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        // (v0.7.9+) 拎走 .padding(.vertical, 4) — user feedback
        // SwiftUI List default row padding 已經夠, 額外加 4pt 令 row 之間太鬆
    }
}

// (v0.7.7+) Custom section header — 比 system default (.subheadline + .secondary) 更有 presence
private struct SectionHeaderLabel: View {
    let title: String
    let systemImage: String
    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .textCase(nil)  // iOS 14+ 默認 uppercase, 我哋要保留原 case
        }
    }
}

private struct DemoEntryCard: View {
    let action: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "play.circle.fill")
                    .font(.title)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading) {
                    Text("一鍵 Demo")
                        .font(.headline)
                    Text("唔使 setup，自動跑完整 STT → LLM → TTS pipeline")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Button {
                action()
            } label: {
                Text("開始 Demo")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.systemGray6))
        )
    }
}

#Preview {
    HomeView()
        .modelContainer(for: [ChatSession.self, Message.self], inMemory: true)
}
