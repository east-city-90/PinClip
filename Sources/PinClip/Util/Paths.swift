import Foundation

/// 应用数据目录布局：
/// ~/Library/Application Support/PinClip/
///   ├── pinclip.db          SQLite 历史库
///   ├── settings.json       设置
///   ├── media/YYYYMMDD/     图片原图 + 缩略图
///   └── CaptureCache/       截图冻结帧临时文件
enum Paths {
    static let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("PinClip", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let dbURL = appSupport.appendingPathComponent("pinclip.db")
    static let settingsURL = appSupport.appendingPathComponent("settings.json")
    /// 贴图恢复状态（重启还原贴图）
    static let pinsURL = appSupport.appendingPathComponent("pins.json")

    static let mediaDir: URL = appSupport.appendingPathComponent("media", isDirectory: true)
    static let captureCacheDir: URL = appSupport.appendingPathComponent("CaptureCache", isDirectory: true)

    /// media 目录按日期分桶，避免单目录文件过多
    static func mediaURL(hash: String, ext: String) -> URL {
        let day = DateFormatter()
        day.dateFormat = "yyyyMMdd"
        let sub = mediaDir.appendingPathComponent(day.string(from: Date()), isDirectory: true)
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        return sub.appendingPathComponent("\(hash).\(ext)")
    }

    static func captureCacheURL(name: String) -> URL {
        try? FileManager.default.createDirectory(at: captureCacheDir, withIntermediateDirectories: true)
        return captureCacheDir.appendingPathComponent(name)
    }

    /// 清空截图冻结帧缓存
    static func clearCaptureCache() {
        try? FileManager.default.removeItem(at: captureCacheDir)
    }
}
