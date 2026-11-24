import AppKit
import Foundation

/// 应用设置（JSON 持久化于 Application Support/PinClip/settings.json）
struct AppSettings: Codable, Sendable, Equatable {
    var hotkeys: [HotkeyAction: HotkeySpec] = [
        .region: .region,
        .fullscreen: .fullscreen,
        .panel: .panel,
        .pin: .pin,
        .pastePlain: .pastePlain,
    ]
    /// 文本历史上限（条）
    var textLimit: Int = 500
    /// 图片保留天数
    var imageDays: Int = 30
    /// 单击条目后自动向原 App 粘贴（需辅助功能权限）
    var autoPaste: Bool = true
    var autoPasteDelayMs: Int = 120
    /// 敏感内容正则过滤（疑似密码/卡号不入库）
    var sensitiveFilter: Bool = true
    /// 排除记录的来源 App bundle id
    var excludedBundles: [String] = [
        "com.1password.1password",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc",
        "com.apple.Passwords",
        "com.agilebits.onepassword-osx",
    ]
    /// 暂停记录
    var paused: Bool = false
    /// 截图保存目录（支持 ~）
    var saveDir: String = "~/Desktop"
    /// 首启引导是否完成
    var firstRunDone: Bool = false
    /// 同时贴图上限
    var pinLimit: Int = 3
    /// 在线获取网站 favicon（仅直接请求目标网站，不用第三方服务）
    var webFaviconEnabled: Bool = true
    /// 截图默认带背景+阴影装饰导出
    var captureDecoration: Bool = false
    /// 选区尺寸角标（截图时左上角显示 W×H，默认关闭）
    var showSizeBadge: Bool = false
    /// 导出水印文字（空 = 不加水印）
    var watermarkText: String = ""
    /// 水印位置：topLeft / topRight / bottomLeft / bottomRight
    var watermarkCorner: String = "bottomRight"
    /// 水印不透明度 0.2–0.9
    var watermarkOpacity: Double = 0.55
    /// Android 设备同步（Mac 剪贴板 ⇄ 手机剪贴板，需 ADB 连接 + device-helper）
    var androidSyncEnabled: Bool = false

    // MARK: v0.2 新增

    /// 外观：system / light / dark
    var appearance: String = "system"
    /// 「延时区域截图」热键的默认延时时长（秒）
    var delaySeconds: Int = 5
    /// 贴图悬停显示色值（⌘单击复制）
    var pinShowColor: Bool = true
    /// 重启后恢复上次的贴图
    var restorePins: Bool = true
    /// 启动时自动检查更新（GitHub Releases，每天至多一次）
    var checkUpdates: Bool = true
    /// 上次自动检查更新时间戳（节流用）
    var lastUpdateCheck: Double = 0
}

extension AppSettings {
    /// 容错解码：旧版本的 settings.json 缺少新键时逐键取默认值，而不是整份回退默认后被覆盖保存。
    /// （合成解码要求键齐全——此前每加一个设置项，老用户升级都会静默丢失自定义热键并重弹首启引导。）
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hotkeys = c.value(.hotkeys, default: hotkeys)
        textLimit = c.value(.textLimit, default: textLimit)
        imageDays = c.value(.imageDays, default: imageDays)
        autoPaste = c.value(.autoPaste, default: autoPaste)
        autoPasteDelayMs = c.value(.autoPasteDelayMs, default: autoPasteDelayMs)
        sensitiveFilter = c.value(.sensitiveFilter, default: sensitiveFilter)
        excludedBundles = c.value(.excludedBundles, default: excludedBundles)
        paused = c.value(.paused, default: paused)
        saveDir = c.value(.saveDir, default: saveDir)
        firstRunDone = c.value(.firstRunDone, default: firstRunDone)
        pinLimit = c.value(.pinLimit, default: pinLimit)
        webFaviconEnabled = c.value(.webFaviconEnabled, default: webFaviconEnabled)
        captureDecoration = c.value(.captureDecoration, default: captureDecoration)
        showSizeBadge = c.value(.showSizeBadge, default: showSizeBadge)
        watermarkText = c.value(.watermarkText, default: watermarkText)
        watermarkCorner = c.value(.watermarkCorner, default: watermarkCorner)
        watermarkOpacity = c.value(.watermarkOpacity, default: watermarkOpacity)
        androidSyncEnabled = c.value(.androidSyncEnabled, default: androidSyncEnabled)
        appearance = c.value(.appearance, default: appearance)
        delaySeconds = c.value(.delaySeconds, default: delaySeconds)
        pinShowColor = c.value(.pinShowColor, default: pinShowColor)
        restorePins = c.value(.restorePins, default: restorePins)
        checkUpdates = c.value(.checkUpdates, default: checkUpdates)
        lastUpdateCheck = c.value(.lastUpdateCheck, default: lastUpdateCheck)

        // 新增热键动作在旧配置文件里不存在：补上默认键（否则该动作永不注册）
        let defaultHotkeys = AppSettings().hotkeys
        for action in HotkeyAction.allCases where hotkeys[action] == nil {
            if let spec = defaultHotkeys[action] { hotkeys[action] = spec }
        }

        // 取值收敛（文件被手改坏时不让异常值进入界面）
        textLimit = min(max(textLimit, 100), 5000)
        imageDays = min(max(imageDays, 1), 365)
        watermarkOpacity = min(max(watermarkOpacity, 0.2), 0.9)
        delaySeconds = min(max(delaySeconds, 1), 60)
        pinLimit = max(1, pinLimit)
        if !["topLeft", "topRight", "bottomLeft", "bottomRight"].contains(watermarkCorner) {
            watermarkCorner = "bottomRight"
        }
        if AppAppearance(rawValue: appearance) == nil { appearance = "system" }
        if saveDir.trimmingCharacters(in: .whitespaces).isEmpty { saveDir = "~/Desktop" }
    }
}

private extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

/// 外观三态（magpie 主题系统：system / light / dark）
enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    /// 应用到整个 App（nil = 跟随系统）
    @MainActor
    static func apply(_ raw: String) {
        switch AppAppearance(rawValue: raw) ?? .system {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// 设置存取（MainActor：设置量小，直接主线程读写）
@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings

    /// 加载时文件存在但无法解析（已原样备份，便于排查）
    private(set) var hadLoadProblem = false

    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL) {
            if let loaded = try? JSONDecoder().decode(AppSettings.self, from: data) {
                self.settings = loaded
            } else {
                // 不再静默回退后覆盖：先把原文件挪开
                let backup = fileURL.appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))")
                try? FileManager.default.moveItem(at: fileURL, to: backup)
                NSLog("PinClip: 设置文件无法解析，已移至 \(backup.path)")
                hadLoadProblem = true
                self.settings = AppSettings()
            }
        } else {
            self.settings = AppSettings()
        }
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(settings)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("PinClip: 保存设置失败 \(error)")
        }
    }
}
