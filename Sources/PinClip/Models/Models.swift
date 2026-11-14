import Foundation

// MARK: - 剪贴条目模型（数据模型见产品设计方案 §5.4）

enum ClipKind: String, Codable, Sendable, CaseIterable {
    case text
    case image
    case files
    case screenshot

    var displayName: String {
        switch self {
        case .text: return "文本"
        case .image: return "图片"
        case .files: return "文件"
        case .screenshot: return "截图"
        }
    }
}

/// 一条历史记录（对应 SQLite items 表）
struct ClipItem: Identifiable, Sendable, Hashable {
    let id: Int64
    let kind: ClipKind
    let textContent: String?      // 文本内容；files 时为换行分隔的路径
    let mediaPath: String?        // 图片原图绝对路径
    let thumbPath: String?        // 缩略图绝对路径
    let sourceApp: String?        // 来源 bundle id；截图为 "screenshot"
    let sourceName: String?       // 来源显示名
    let sourceURL: String?        // 来源 URL（复制链接/URL 文本时可得）
    let width: Int?
    let height: Int?
    let pinned: Bool
    let hitCount: Int
    let createdAt: Date
    let charCount: Int?
}

struct HistoryPage: Sendable {
    let pinned: [ClipItem]
    let items: [ClipItem]
}

enum HistoryFilter: String, CaseIterable, Sendable {
    case all, text, image, files

    var label: String {
        switch self {
        case .all: return "全部"
        case .text: return "文本"
        case .image: return "图片"
        case .files: return "文件"
        }
    }

    /// SQL kind 匹配集合（image 过滤同时包含 screenshot）
    var sqlKinds: [String] {
        switch self {
        case .all: return []
        case .text: return [ClipKind.text.rawValue]
        case .image: return [ClipKind.image.rawValue, ClipKind.screenshot.rawValue]
        case .files: return [ClipKind.files.rawValue]
        }
    }
}

// MARK: - 来源应用

struct AppSource: Sendable, Hashable {
    let bundleID: String?     // com.apple.Safari；截图来源固定 "screenshot"
    let name: String?         // Safari

    static let screenshot = AppSource(bundleID: "screenshot", name: "截图")
}

// MARK: - 窗口吸附

/// CGWindowList 返回的可吸附窗口（坐标：全局屏幕空间，左上原点，单位 point）
struct SnapWindow: Sendable, Identifiable {
    let id: UInt32            // CGWindowID
    let title: String
    let appName: String
    let rect: CGRect          // 全局，左上原点，point
}

// MARK: - 热键

enum HotkeyAction: String, Codable, CaseIterable, Sendable {
    case region       // 区域截图 ⌥A
    case fullscreen   // 全屏截图 ⌥S
    case panel        // 剪贴板面板 ⌥V
    case pin          // 贴图 F3

    var displayName: String {
        switch self {
        case .region: return "区域截图"
        case .fullscreen: return "全屏截图"
        case .panel: return "剪贴板面板"
        case .pin: return "贴图"
        }
    }
}

/// 热键规格：Carbon 修饰键掩码 + 键码，可 JSON 持久化
struct HotkeySpec: Codable, Sendable, Equatable {
    var keyCode: UInt32
    var useCommand: Bool
    var useOption: Bool
    var useControl: Bool
    var useShift: Bool
    var display: String     // 如 "⌥A"

    static let region = HotkeySpec(keyCode: 0x00, useCommand: false, useOption: true, useControl: false, useShift: false, display: "⌥A")   // A
    static let fullscreen = HotkeySpec(keyCode: 0x01, useCommand: false, useOption: true, useControl: false, useShift: false, display: "⌥S") // S
    static let panel = HotkeySpec(keyCode: 0x09, useCommand: false, useOption: true, useControl: false, useShift: false, display: "⌥V")   // V
    static let pin = HotkeySpec(keyCode: 0x63, useCommand: false, useOption: false, useControl: false, useShift: false, display: "F3")    // F3
}

// MARK: - 截图会话

enum CaptureAction: Sendable {
    case copy
    case save
    case pin
}

/// 面板请求贴图的结果
enum PinRequestResult: Sendable {
    case ok
    case limitReached
    case notImage
}

// MARK: - 通知名（Rust 方案的 emit 事件对应物）

extension Notification.Name {
    /// 历史数据变化（新增/删除/清理），面板监听刷新
    static let pinclipHistoryChanged = Notification.Name("pinclip.history.changed")
    /// 暂停状态变化
    static let pinclipPausedChanged = Notification.Name("pinclip.paused.changed")
    /// 贴图数量达上限等提示
    static let pinclipToast = Notification.Name("pinclip.toast")
}
