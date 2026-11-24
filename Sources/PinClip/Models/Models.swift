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
    let textContent: String?      // 文本内容；files 时为换行分隔路径
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

    /// 单个图片文件的 files 条目 → 该文件路径（其余情况为 nil）
    var imageFilePath: String? {
        guard kind == .files, let text = textContent, !text.contains("\n") else { return nil }
        return ImageFileTypes.isImage(path: text) ? text : nil
    }

    /// 需要按图片展示的条目：剪贴板图片 / 截图 / 单个图片文件
    var isVisual: Bool {
        kind == .image || kind == .screenshot || imageFilePath != nil
    }

    /// 详情大图的来源文件（历史原图，或图片文件本身）
    var displayImagePath: String? {
        if kind == .image || kind == .screenshot { return mediaPath }
        return imageFilePath
    }
}

struct HistoryPage: Sendable {
    let pinned: [ClipItem]
    let items: [ClipItem]
    /// 列表末尾是否还有更早的条目（滚动到底时增量加载）
    let hasMore: Bool

    init(pinned: [ClipItem], items: [ClipItem], hasMore: Bool = false) {
        self.pinned = pinned
        self.items = items
        self.hasMore = hasMore
    }
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

    /// SQL kind 匹配集合（image 过滤同时包含 screenshot；图片文件条目在 HistoryStore.page 里另行并入）
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
    let bundleID: String?     // com.apple.Safari；截图来源 "screenshot"
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
    case pastePlain   // 纯文本粘贴 ⇧⌥V（去掉格式后粘到前台应用）
    case delayedRegion // 延时区域截图（默认不绑定，托盘菜单也可触发）

    var displayName: String {
        switch self {
        case .region: return "区域截图"
        case .fullscreen: return "全屏截图"
        case .panel: return "剪贴板面板"
        case .pin: return "贴图"
        case .pastePlain: return "纯文本粘贴"
        case .delayedRegion: return "延时区域截图"
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
    /// ⌥V 的变体：按住 ⇧ = 纯文本粘贴
    static let pastePlain = HotkeySpec(keyCode: 0x09, useCommand: false, useOption: true, useControl: false, useShift: true, display: "⇧⌥V")

    /// 功能键名（现行 kVK 键码表）
    static func functionName(keyCode: UInt32) -> String? {
        switch keyCode {
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default: return nil
        }
    }

    /// 录制时展示用的键名（字母/数字用大写字符，功能键按键码表）
    static func keyName(keyCode: UInt32, chars: String) -> String {
        if let name = functionName(keyCode: keyCode) { return name }
        return chars.uppercased()
    }
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
