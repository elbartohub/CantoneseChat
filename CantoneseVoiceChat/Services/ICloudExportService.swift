import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// iCloud Drive export service (v0.7.3) — 將 TTS Lab 嘅 audio 寫到 user 揀嘅 iCloud folder
/// 自動 mkdir "TTSVoice/" subdirectory + 用 bookmark 記住 user 嘅 folder choice
@MainActor
final class ICloudExportService: ObservableObject {

    /// Shared singleton (v0.7.4) — Settings 同 TtsLabView 共享同一 instance,
    /// bookmark reset 即時反映兩邊 UI
    static let shared = ICloudExportService()

    enum ExportState: Equatable {
        case idle
        case picking       // Document picker 開緊
        case exporting
        case success(String)  // 成功, payload = 寫入嘅 absolute URL string
        case error(String)
    }

    @Published var state: ExportState = .idle
    @Published var pickedFolderType: PickedFolderType = .unknown

    /// Bookmark 嘅 user defaults key (記住 user 揀嘅 iCloud folder)
    private static let bookmarkKey = "ttsLab.icloudFolderBookmark"

    /// Subdirectory 名 (user 揀 folder 之後 mkdir 呢個)
    static let subdirectoryName = "TTSVoice"

    /// iCloud 揀 folder 時要 resolve bookmark (跨 app launch 持久化)
    /// bookmark isData 內含 scoped resource info, iOS 識自動處理 iCloud 同步
    func savedFolderURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else {
            print("[ICloudExport] savedFolderURL: 冇 bookmark data")
            return nil
        }
        var isStale = false
        let url: URL
        do {
            // (v0.7.7) iOS 上 security scope 已經係 default (選項名係 macOS only)
            url = try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            print("[ICloudExport] resolve bookmark FAILED: \(error.localizedDescription)")
            UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
            return nil
        }
        // Detect folder type (iCloud vs local)
        pickedFolderType = ICloudExportService.detectFolderType(url)
        print("[ICloudExport] resolved bookmark: \(url.lastPathComponent) type=\(pickedFolderType) stale=\(isStale)")
        if isStale {
            // (v0.7.7) Stale bookmark → 嘗試 refresh, 唔直接 clear
            if let newData = try? url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                UserDefaults.standard.set(newData, forKey: Self.bookmarkKey)
                print("[ICloudExport] bookmark stale → refreshed, 繼續")
            } else {
                print("[ICloudExport] bookmark stale, refresh FAILED → clear, 叫 user 再揀")
                UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
                return nil
            }
        }
        // (v0.7.7) 每次 export 都要 start access — caller 負責 stop
        let didStart = url.startAccessingSecurityScopedResource()
        print("[ICloudExport] startAccessingSecurityScopedResource → \(didStart)")
        if !didStart {
            return nil
        }
        return url
    }

    /// 第一次 user 揀完 folder 後, save bookmark
    /// (v0.7.8+) 用 `options: []` 預設 (include security scope) 而唔係 `.minimalBookmark`
    /// 原因: `.minimalBookmark` 對 iOS file provider (UIDocumentPicker forExport) 嘅 URL 唔 friendly,
    /// 會 throw "檔案不存在"。預設 options 對 iCloud Drive 內 folder 較 reliable。
    func saveFolderBookmark(_ url: URL) {
        do {
            let data = try url.bookmarkData(
                options: [],  // (v0.7.8+) 預設 including security scope, 唔用 .minimalBookmark
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
            print("[ICloudExport] saved folder bookmark: \(url.lastPathComponent) (\(data.count)B)")
        } catch {
            print("[ICloudExport] save bookmark FAILED: \(error.localizedDescription) — user 撳 Save to iCloud 會再彈 picker")
        }
    }

    /// 清咗 saved bookmark (v0.7.4)
    /// User 想換 iCloud folder 嘅時候用呢個, 然後再撳 Save to iCloud 揀新 folder
    /// 同時 reset pickedFolderType + state
    func resetFolderBookmark() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        pickedFolderType = .unknown
        state = .idle
        print("[ICloudExport] reset folder bookmark")
    }

    /// Helper: 有冇 saved folder bookmark (用嚟 show/hide reset button)
    var hasSavedBookmark: Bool {
        UserDefaults.standard.data(forKey: Self.bookmarkKey) != nil
    }

    /// 將 mp3 data 寫到 iCloud folder/TTSVoice/filename.mp3
    /// 自動 mkdir "TTSVoice/" 如果唔存在
    /// - Parameters:
    ///   - data: mp3 file data
    ///   - filename: e.g. "chengyu-2026-06-18-061200.mp3"
    ///   - parentFolder: 由 user 揀嘅 folder URL (iCloud Drive 內任何 folder)
    /// - Returns: 寫入嘅絕對 URL
    /// Mutable error holder (避免 inout + closure exclusive access 衝突)
    private final class ErrBox { var err: NSError? }

    func writeToICloud(data: Data, filename: String, parentFolder: URL) throws -> URL {
        print("[ICloudExport] writeToICloud enter: file=\(filename) parent=\(parentFolder.lastPathComponent)")

        // (v0.7.7) Caller (export()) 已經 startAccessing security scope,
        // 呢度只負責 mkdir + write, defer stop 喺 export() 入面做
        let fm = FileManager.default
        let ttsVoiceDir = parentFolder.appendingPathComponent(Self.subdirectoryName, isDirectory: true)
        if !fm.fileExists(atPath: ttsVoiceDir.path) {
            do {
                try fm.createDirectory(at: ttsVoiceDir, withIntermediateDirectories: true)
                print("[ICloudExport] mkdir OK: \(ttsVoiceDir.path)")
            } catch {
                print("[ICloudExport] mkdir FAILED: \(error.localizedDescription)")
                throw error
            }
        }

        let fileURL = ttsVoiceDir.appendingPathComponent(filename)
        print("[ICloudExport] writing \(data.count)B to \(fileURL.path)")
        do {
            try data.write(to: fileURL, options: .atomic)
            print("[ICloudExport] write OK: \(fileURL.path)")
        } catch {
            print("[ICloudExport] write FAILED: \(error.localizedDescription)")
            throw error
        }
        return fileURL
    }

    /// 完整 export flow: 用 savedFolderURL 即寫, 或者要 user 揀新 folder
    /// View layer 應該 call 呢個; picker presentation 由 View 處理
    func export(data: Data, filename: String) async {
        guard let folder = savedFolderURL() else {
            // (v0.7.7) savedFolderURL() 入面 startAccessing 唔一定成功,
            // 失敗 → state 已經 nil, 但 caller 冇收到, 所以要明確設 error
            state = .error("iCloud folder permission 失效, 請喺 Settings 重揀 folder")
            return
        }
        // (v0.7.7) savedFolderURL() 入面 startAccessing 成功, 喺度 stop
        defer { folder.stopAccessingSecurityScopedResource() }
        state = .exporting
        do {
            let url = try writeToICloud(data: data, filename: filename, parentFolder: folder)
            state = .success(url.path)
        } catch {
            state = .error("寫入失敗: \(error.localizedDescription)")
        }
    }

    /// User 喺 document picker 揀完 folder 後 call 呢個
    /// (v0.7.8+) Reordered: 1) 立即 export  2) 成功後先 save bookmark
    /// 原因: UIDocumentPicker forExport 嘅 iCloud URL 喺 picker 剛 dismiss 嗰陣 file system 仲
    /// 未 fully mount, save bookmark 可能 throw "檔案不存在"。先 write file 確保 mount, 然後
    /// save bookmark 較 reliable。
    func handlePickedFolder(_ url: URL, data: Data, filename: String) {
        // (v0.7.7) 同 export() 一樣, caller 負責 start/stop
        let didStart = url.startAccessingSecurityScopedResource()
        print("[ICloudExport] handlePickedFolder startAccessing → \(didStart)")
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
        pickedFolderType = ICloudExportService.detectFolderType(url)
        state = .exporting
        do {
            let written = try writeToICloud(data: data, filename: filename, parentFolder: url)
            state = .success(written.path)
            // (v0.7.8+) Write success 先 save bookmark (file system 已 mount)
            saveFolderBookmark(url)
        } catch {
            state = .error("寫入失敗: \(error.localizedDescription)")
        }
    }

    /// Reset state (e.g. dismiss error banner)
    func reset() {
        state = .idle
    }

    // MARK: - Test accessors (internal so @testable can reach)

    /// Test-only: 純 slugify, 唔 generate timestamp
    func slugifyForTest(_ text: String) -> String {
        let ascii = text.lowercased()
            .replacingOccurrences(of: " ", with: "-")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        return String(ascii.unicodeScalars.filter { allowed.contains($0) })
    }

    /// Test-only: generate filename 用指定 text (v0.7.8+ spec: 文字前10字 + yyyy-MM-dd-HHmmss)
    func generateFilenameForTest(text: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let dateStr = formatter.string(from: Date())
        let allowed = CharacterSet.alphanumerics
        let filtered = String(text.unicodeScalars.filter { allowed.contains($0) })
        let textSlug = String(filtered.prefix(10))
        let finalSlug = textSlug.isEmpty ? "tts" : textSlug
        return "\(finalSlug)-\(dateStr).mp3"
    }

    /// Test-only: writeToICloud 嘅 wrapper, 唔 trigger security scope
    /// (real export 用 security-scoped resource, test 用 temp dir 唔需要)
    func writeToICloudForTest(data: Data, filename: String, parentFolder: URL) throws -> URL {
        let fm = FileManager.default
        let ttsVoiceDir = parentFolder.appendingPathComponent(ICloudExportService.subdirectoryName, isDirectory: true)
        if !fm.fileExists(atPath: ttsVoiceDir.path) {
            try fm.createDirectory(at: ttsVoiceDir, withIntermediateDirectories: true)
        }
        let fileURL = ttsVoiceDir.appendingPathComponent(filename)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }
}

/// SwiftUI wrapper for UIDocumentPickerViewController (folder mode)
/// User 撳完 folder → call `onPick: (URL) -> Void`
struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.folder],
            asCopy: false
        )
        picker.delegate = context.coordinator
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: FolderPicker

        init(_ parent: FolderPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first {
                parent.onPick(url)
            } else {
                parent.onCancel()
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}

/// User 揀咗嘅 folder 嘅 type (v0.7.4)
/// .iCloud = file 會 sync 落 iCloud Drive (server)
/// .local = file 寫入 iPhone 本地 sandbox, 唔會 sync
enum PickedFolderType: Equatable {
    case iCloud
    case local
    case unknown

    var emoji: String {
        switch self {
        case .iCloud: return "☁️"
        case .local:  return "📱"
        case .unknown: return "❓"
        }
    }

    var label: String {
        switch self {
        case .iCloud:  return "iCloud Drive (會同步)"
        case .local:   return "本機 (不會同步)"
        case .unknown: return "未知"
        }
    }

    // (v0.7.8+) warningMessage 移除 — TTS Lab 唔再顯示 warning banner
    // 如將來要加 hint, 改用 toast / onboarding flow 而唔係常駐 banner
}

extension ICloudExportService {
    /// Detect folder type (iCloud Drive vs On My iPhone vs unknown)
    /// 用 URL path pattern 同 file resource values 雙重 check
    static func detectFolderType(_ url: URL) -> PickedFolderType {
        let path = url.path

        // 1) iCloud Drive path 包含 `Mobile Documents/com~apple~CloudDocs/`
        //    On My iPhone path 包含 `File Provider Storage/.../On My iPhone/...` 或 app sandbox
        if path.contains("Mobile Documents/com~apple~CloudDocs") {
            return .iCloud
        }
        // 2) 試 `URLResourceValues` 攞 `volume.isLocal`
        //    On My iPhone (or 其他 local) → volume isLocal = true
        //    iCloud Drive → volume isLocal = false
        do {
            let values = try url.resourceValues(forKeys: [
                .volumeIsLocalKey,
                .volumeIsRemovableKey,
                .volumeIsInternalKey,
            ])
            // volumeIsLocal = true → On My iPhone (或 removable disk)
            // volumeIsLocal = false → iCloud Drive (cloud) 或 network
            if values.volumeIsLocal == true {
                return .local
            } else if values.volumeIsLocal == false {
                return .iCloud
            }
        } catch {
            print("[ICloudExport] resourceValues failed: \(error.localizedDescription), fallback to path check")
        }
        return .unknown
    }
}
