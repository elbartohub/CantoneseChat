import Foundation

/// TTS audio cache: 將 sync TTS 嘅 mp3 data 寫入 Caches/tts-cache/，
/// 之後 replay 唔再 call API，直接 read file 播。
/// 路徑設計：絕對路徑唔入 SwiftData（iCloud backup / migration 會 break），
/// 只 save 相對 path "tts-cache/<uuid>.mp3"，runtime 解 absolute URL。
enum TTSCache {

    /// Caches dir 入面嘅子目錄
    static let subdirectory = "tts-cache"

    /// 取得絕對 cache dir URL（會自動 mkdir）
    static var cacheDir: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent(subdirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 將 mp3 data 寫入 cache, return 相對 path "tts-cache/<uuid>.mp3"
    @discardableResult
    static func write(_ data: Data) throws -> String {
        let fileURL = cacheDir.appendingPathComponent("\(UUID().uuidString).mp3")
        try data.write(to: fileURL, options: .atomic)
        return "\(subdirectory)/\(fileURL.lastPathComponent)"
    }

    /// 將相對 path 解做絕對 URL（檔案唔存在返 nil）
    static func absoluteURL(for relativePath: String) -> URL? {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let url = caches.appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 刪一個 cache file (chat delete 時 call), silent fail if missing
    static func delete(relativePath: String) {
        guard let url = absoluteURL(for: relativePath) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 批量刪 (刪整個 chat 嗰陣用)
    static func deleteAll(relativePaths: [String]) {
        for p in relativePaths { delete(relativePath: p) }
    }
}
