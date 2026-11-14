import AppKit
import Observation

/// 面板动作回调（PanelController 实现，视图层通过协议调用，解耦窗口管理）
@MainActor
protocol PanelActions: AnyObject {
    /// 回填剪贴板；paste=true 时向原 App 自动粘贴
    func activate(_ item: ClipItem, paste: Bool)
    /// 仅复制为纯文本
    func copyPlain(_ item: ClipItem)
    func togglePin(_ item: ClipItem)
    func delete(_ item: ClipItem)
    /// 历史图片 → 贴图浮窗
    func pinToScreen(_ item: ClipItem) -> PinRequestResult
    func hidePanel()
    func openSettings()
    /// 引导页「开始使用」：标记完成并隐藏引导
    func dismissOnboarding()
}

/// 全局可观察状态：权限、暂停、设置入口（SwiftUI 视图订阅）
@MainActor
@Observable
final class AppState {
    var settings: AppSettings
    var screenPermission = false
    var axPermission = false
    var paused = false
    /// 截图时发现权限缺失 → 强制展示权限引导（首启之外的场景）
    var showPermissionGuide = false
    /// 面板内 toast 文案（nil 隐藏）
    var toastText: String?

    let settingsStore: SettingsStore

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        self.settings = settingsStore.settings
        self.paused = settingsStore.settings.paused
    }

    // MARK: 权限

    func refreshPermissions() {
        screenPermission = ScreenCapture.preflightGranted()
        axPermission = AutoPaste.isProcessTrusted(prompt: false)
    }

    /// 触发系统屏幕录制权限弹窗（仅首次有效），返回当前授权状态
    func requestScreenPermission() async {
        await ScreenCapture.requestPermission()
        refreshPermissions()
    }

    func openScreenPermissionSettings() {
        PermissionOpener.openScreenRecording()
    }

    func openAXPermissionSettings() {
        PermissionOpener.openAccessibility()
    }

    // MARK: 设置

    func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        mutate(&settings)
        settingsStore.settings = settings
        settingsStore.save()
        if paused != settings.paused {
            paused = settings.paused
            NotificationCenter.default.post(name: .pinclipPausedChanged, object: nil)
        }
    }

    /// 重新绑定热键；返回 false 表示注册失败（冲突）
    @discardableResult
    func rebindHotkey(_ action: HotkeyAction, _ spec: HotkeySpec) -> Bool {
        guard let manager = hotkeyManager else { return false }
        let ok = manager.rebind(action: action, spec: spec)
        if ok {
            updateSettings { $0.hotkeys[action] = spec }
        }
        return ok
    }

    func resetHotkeys() {
        let defaults: [HotkeyAction: HotkeySpec] = [
            .region: .region, .fullscreen: .fullscreen, .panel: .panel, .pin: .pin,
        ]
        guard let manager = hotkeyManager else { return }
        for (action, spec) in defaults {
            manager.rebind(action: action, spec: spec)
        }
        updateSettings { $0.hotkeys = defaults }
    }

    /// 启动时注入（AppDelegate 组装）
    weak var hotkeyManager: HotKeyManager?
    weak var launchManager: (any LaunchAtStartupManaging)?
    weak var historyStore: HistoryStore?
    weak var panelActions: (any PanelActions)?

    func openSaveFolder() {
        let dir = Paths.mediaDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    func showToast(_ text: String) {
        toastText = text
        NotificationCenter.default.post(name: .pinclipToast, object: nil)
    }
}

/// 打开系统设置对应隐私面板
enum PermissionOpener {
    static func openScreenRecording() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openAccessibility() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func open(_ url: String) {
        if let u = URL(string: url) {
            NSWorkspace.shared.open(u)
        }
    }
}
