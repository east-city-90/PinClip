import AppKit

/// 菜单栏常驻图标 + 菜单（设计方案 §3.2：停止/启动剪贴板记录在菜单栏开关）
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    struct Actions {
        let regionCapture: () -> Void
        let delayedRegionCapture: () -> Void
        let fullscreenCapture: () -> Void
        let togglePanel: () -> Void
        let pinFromClipboard: () -> Void
        let pastePlainText: () -> Void
        let checkUpdates: () -> Void
        let openSettings: () -> Void
        let quit: () -> Void
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let actions: Actions
    private weak var appState: AppState?
    private weak var hotkeys: HotKeyManager?
    private var pauseItem: NSMenuItem?

    init(actions: Actions, appState: AppState, hotkeys: HotKeyManager) {
        self.actions = actions
        self.appState = appState
        self.hotkeys = hotkeys
        super.init()
        menu.delegate = self
        buildMenu()
        statusItem.menu = menu
        if let button = statusItem.button {
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            let icon = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "PinClip")?
                .withSymbolConfiguration(config)
            icon?.isTemplate = true
            button.image = icon
            button.toolTip = "PinClip 贴剪"
        }
    }

    /// 打开菜单时刷新快捷键显示与暂停状态
    private func buildMenu() {
        menu.removeAllItems()
        let settings = appState?.settings ?? AppSettings()

        let panelItem = menu.addItem(withTitle: "剪贴板面板", action: #selector(togglePanelAction), keyEquivalent: "")
        panelItem.target = self
        let regionItem = menu.addItem(withTitle: "区域截图", action: #selector(regionAction), keyEquivalent: "")
        regionItem.target = self
        let delayedItem = menu.addItem(withTitle: "延时区域截图（\(settings.delaySeconds) 秒）", action: #selector(delayedRegionAction), keyEquivalent: "")
        delayedItem.target = self
        let fullItem = menu.addItem(withTitle: "全屏截图", action: #selector(fullscreenAction), keyEquivalent: "")
        fullItem.target = self
        let pinItem = menu.addItem(withTitle: "贴图（剪贴板当前图）", action: #selector(pinAction), keyEquivalent: "")
        pinItem.target = self
        let plainItem = menu.addItem(withTitle: "纯文本粘贴", action: #selector(pastePlainAction), keyEquivalent: "")
        plainItem.target = self

        // 快捷键展示：修饰键组合 → 菜单键符；F 键 → 标题后缀（系统菜单键符不支持 F 键直书）
        let pairs: [(NSMenuItem, HotkeyAction)] = [
            (panelItem, .panel), (regionItem, .region), (fullItem, .fullscreen),
            (pinItem, .pin), (plainItem, .pastePlain),
        ]
        for (item, action) in pairs {
            if let spec = settings.hotkeys[action] ?? hotkeys?.spec(for: action) {
                if let fname = HotkeySpec.functionName(keyCode: spec.keyCode) {
                    item.title += "（\(fname)）"
                } else {
                    item.keyEquivalent = keyEquivalentString(for: spec)
                    item.keyEquivalentModifierMask = modifierMask(for: spec)
                }
            }
        }

        menu.addItem(.separator())
        let pause = menu.addItem(withTitle: "暂停记录", action: #selector(togglePauseAction), keyEquivalent: "")
        pause.target = self
        pause.state = settings.paused ? NSControl.StateValue.on : .off
        pauseItem = pause

        menu.addItem(.separator())
        let updateItem = menu.addItem(withTitle: "检查更新…", action: #selector(checkUpdatesAction), keyEquivalent: "")
        updateItem.target = self
        let settingsItem = menu.addItem(withTitle: "设置…", action: #selector(settingsAction), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.keyEquivalentModifierMask = .command
        let about = menu.addItem(withTitle: "关于 PinClip", action: #selector(aboutAction), keyEquivalent: "")
        about.target = self
        let quit = menu.addItem(withTitle: "退出 PinClip", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        quit.keyEquivalentModifierMask = .command
    }

    // MARK: 菜单事件

    @objc private func togglePanelAction() { actions.togglePanel() }
    @objc private func regionAction() { actions.regionCapture() }
    @objc private func delayedRegionAction() { actions.delayedRegionCapture() }
    @objc private func fullscreenAction() { actions.fullscreenCapture() }
    @objc private func pinAction() { actions.pinFromClipboard() }
    @objc private func pastePlainAction() { actions.pastePlainText() }
    @objc private func checkUpdatesAction() { actions.checkUpdates() }
    @objc private func settingsAction() { actions.openSettings() }
    @objc private func quitAction() { actions.quit() }

    @objc private func aboutAction() {
        // 标准关于面板（版本号读 Info.plist；此前 toast 里写死 v0.1.0）
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSAttributedString(string: "截图 + 贴图 + 剪贴板历史，三合一轻量工具\n全本地处理 · 无遥测 · MIT License")
        NSApp.orderFrontStandardAboutPanel(options: [
            NSApplication.AboutPanelOptionKey.credits: credits,
        ])
    }

    @objc private func togglePauseAction() {
        appState?.updateSettings { $0.paused.toggle() }
        pauseItem?.state = (appState?.settings.paused ?? false) ? NSControl.StateValue.on : .off
    }

    // MARK: 快捷键展示（⌥A → 菜单键符）

    private func keyEquivalentString(for spec: HotkeySpec) -> String {
        let map: [UInt32: String] = [
            0x00: "a", 0x01: "s", 0x02: "d", 0x03: "f", 0x09: "v", 0x0B: "b",
            0x14: "e", 0x0D: "w", 0x0F: "r",
        ]
        return map[spec.keyCode] ?? String(Character(UnicodeScalar(UInt8(spec.keyCode + 0x61))))
    }

    private func modifierMask(for spec: HotkeySpec) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if spec.useCommand { flags.insert(.command) }
        if spec.useOption { flags.insert(.option) }
        if spec.useControl { flags.insert(.control) }
        if spec.useShift { flags.insert(.shift) }
        return flags
    }
}
