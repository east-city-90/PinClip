import Foundation

/// 应用设置（JSON 持久化于 Application Support/PinClip/settings.json）
struct AppSettings: Codable, Sendable, Equatable {
    var hotkeys: [HotkeyAction: HotkeySpec] = [
        .region: .region,
        .fullscreen: .fullscreen,
        .panel: .panel,
        .pin: .pin,
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
    /// 截图保存目录
    var saveDir: String = "~/Desktop"
    /// 首启引导是否完成
    var firstRunDone: Bool = false
    /// 免费版贴图上限
    var pinLimit: Int = 3
    /// 在线获取网站 favicon（仅直接请求目标网站，不用第三方服务）
    var webFaviconEnabled: Bool = true
    /// 截图默认带背景+阴影装饰导出
    var captureDecoration: Bool = false
}

/// 设置存取（MainActor：设置量小，直接主线程读写）
@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings

    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = loaded
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
