import AppKit
import UserNotifications

/// 应用组装与调度中枢：热键 → 截图/面板/贴图 流程编排
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settingsStore: SettingsStore
    let appState: AppState
    let historyStore: HistoryStore
    let clipboardMonitor: ClipboardMonitor
    let hotkeyManager = HotKeyManager()
    let launchManager = LaunchAtStartupManager()
    let overlayController = OverlayController()
    let pinController = PinWindowController()
    let settingsWindow: SettingsWindowController
    let panelController: PanelController
    /// lazy：闭包捕获 self，需在完整初始化后求值
    private lazy var statusItem = StatusItemController(
        actions: StatusItemController.Actions(
            regionCapture: { [weak self] in self?.startRegionCapture() },
            fullscreenCapture: { [weak self] in self?.startFullscreenCapture() },
            togglePanel: { [weak self] in self?.panelController.togglePanel() },
            pinFromClipboard: { [weak self] in self?.pinFromClipboard() },
            openSettings: { [weak self] in self?.settingsWindow.show() },
            quit: { NSApp.terminate(nil) }
        ),
        appState: appState,
        hotkeys: hotkeyManager
    )

    override init() {
        // Swift 两段式初始化：先完成自有存储属性，再 super.init()，最后才允许捕获 self
        let store = SettingsStore(fileURL: Paths.settingsURL)
        settingsStore = store
        appState = AppState(settingsStore: store)
        historyStore = HistoryStore(settingsProvider: { [weak appState] in
            appState?.settings ?? AppSettings()
        })
        clipboardMonitor = ClipboardMonitor(store: historyStore, settingsProvider: { [weak appState] in
            appState?.settings ?? AppSettings()
        })
        settingsWindow = SettingsWindowController(appState: appState)
        panelController = PanelController(
            appState: appState,
            store: historyStore,
            pinController: pinController,
            settingsWindow: settingsWindow
        )
        super.init()

        appState.hotkeyManager = hotkeyManager
        appState.launchManager = launchManager
        appState.historyStore = historyStore
        appState.panelActions = panelController
        pinController.appState = appState
        overlayController.onResult = { [weak self] result in
            self?.handleCaptureResult(result)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = statusItem // 触发 lazy 创建：菜单栏图标必须在启动时挂上
        installDebugNotify()
        registerHotkeys()
        clipboardMonitor.start()
        historyStore.startRetentionLoop(settingsProvider: { [weak appState] in
            appState?.settings ?? AppSettings()
        })

        // 首启/权限缺失 → 面板展示引导（设计方案 §6 权限引导）
        appState.refreshPermissions()
        if !appState.screenPermission || !appState.settings.firstRunDone {
            panelController.showPanel()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardMonitor.stop()
    }

    // MARK: 开发调试信号（notifyutil -p pinclip.debugshot：弹面板并自截屏到 /tmp/pinclip-ui.png）

    private var debugNotifyInstalled = false

    private func installDebugNotify() {
        guard !debugNotifyInstalled else { return }
        debugNotifyInstalled = true
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        // Darwin 通知中心必须显式注册每个通知名（name=nil 观察全部不生效）
        for signal in ["pinclip.debugshot", "pinclip.debugsettings", "pinclip.debugcapture", "pinclip.debugcancel"] {
            CFNotificationCenterAddObserver(
                center,
                Unmanaged.passUnretained(self).toOpaque(),
                { (_, observer, name, _, _) in
                    guard let observer, let name else { return }
                    let signal = name.rawValue as String
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
                                .handleDebugSignal(signal)
                        }
                    }
                },
                signal as CFString,
                nil,
                .deliverImmediately
            )
        }
    }

    fileprivate func handleDebugSignal(_ signal: String) {
        switch signal {
        case "pinclip.debugsettings":
            settingsWindow.show(initialSection: .hotkeys)
            return
        case "pinclip.debugcapture":
            // 先让面板在屏（作为截图内容），再框选覆盖面板区域 —— 产出不含桌面上其他 App 的干净演示图
            panelController.showPanel()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard let self else { return }
                // 用 CGWindow 实际合成 frame（NSWindow.frame 可能与合成位置有 0.9 重排偏差）
                let panelFrame = SnapWindows.actualFrame(
                    pid: ProcessInfo.processInfo.processIdentifier,
                    minWidth: 200
                ) ?? self.panelController.panelWindow.frame
                let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? panelFrame.maxY
                let globalTLRect = CGRect(
                    x: panelFrame.minX, y: primaryMaxY - panelFrame.maxY,
                    width: panelFrame.width, height: panelFrame.height
                )
                self.startRegionCapture()
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                self.overlayController.debugAutoSelectDemo(coveringRect: globalTLRect)
            }
            return
        case "pinclip.debugcancel":
            overlayController.cancel()
            return
        case "pinclip.debugshot":
            break
        default:
            return
        }
        panelController.showPanel()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard let self else { return }
            let panel = panelController.panelWindow
            NSLog("PinClip.debug: panel visible=\(panel.isVisible) frame=\(panel.frame) preflight=\(ScreenCapture.preflightGranted())")

            // 面板 frame（左下原点全局坐标）→ 转全局左上坐标
            let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? panel.frame.maxY
            let tlX = panel.frame.minX
            let tlY = primaryMaxY - panel.frame.maxY

            for (screen, displayID) in ScreenCapture.screensWithIDs() {
                do {
                    let image = try await ScreenCapture.captureDisplay(displayID)
                    let topLeft = ScreenGeometry.screenTopLeft(of: screen)
                    let scale = ScreenCapture.backingScale(of: displayID)
                    // 面板在该屏图像里的像素裁剪区（钳制到图像范围）
                    let cx = max(0, (tlX - topLeft.x) * scale)
                    let cy = max(0, (tlY - topLeft.y) * scale)
                    let cw = min(panel.frame.width * scale, CGFloat(image.width) - cx)
                    let ch = min(panel.frame.height * scale, CGFloat(image.height) - cy)
                    let cropRect = CGRect(x: cx, y: cy, width: max(cw, 10), height: max(ch, 10))
                    if let crop = image.cropping(to: cropRect), let png = ImageKit.pngData(crop) {
                        try png.write(to: URL(fileURLWithPath: "/tmp/pinclip-ui-crop.png"))
                        NSLog("PinClip.debug: display \(displayID) 面板裁剪 -> /tmp/pinclip-ui-crop.png (\(png.count) bytes, crop=\(cropRect))")
                    }
                    // 全帧也存一份用于对照
                    if let fullPng = ImageKit.pngData(image) {
                        try fullPng.write(to: URL(fileURLWithPath: "/tmp/pinclip-ui-full.png"))
                    }
                } catch {
                    NSLog("PinClip.debug: display \(displayID) 截屏失败 \(error)")
                }
            }
        }
    }

    // MARK: 热键注册（冲突自动降级到备选键，设计方案 §3.2）

    private func registerHotkeys() {
        let settings = settingsStore.settings
        let specs = settings.hotkeys
        let fallbacks: [HotkeyAction: [HotkeySpec]] = [
            .region: [HotkeySpec(keyCode: 0x02, useCommand: false, useOption: true, useControl: false, useShift: false, display: "⌥D")],   // ⌥D
            .fullscreen: [HotkeySpec(keyCode: 0x14, useCommand: false, useOption: true, useControl: false, useShift: false, display: "⌥E")], // ⌥E
            .panel: [HotkeySpec(keyCode: 0x0B, useCommand: false, useOption: true, useControl: false, useShift: false, display: "⌥B")],     // ⌥B
            .pin: [HotkeySpec(keyCode: 0x76, useCommand: false, useOption: false, useControl: false, useShift: false, display: "F4")],      // F4
        ]
        let handlers: [HotkeyAction: () -> Void] = [
            .region: { [weak self] in self?.startRegionCapture() },
            .fullscreen: { [weak self] in self?.startFullscreenCapture() },
            .panel: { [weak self] in self?.panelController.togglePanel() },
            .pin: { [weak self] in self?.pinFromClipboard() },
        ]
        let failures = hotkeyManager.registerAll(specs: specs, handlers: handlers, fallbacks: fallbacks)

        // 记录实际生效键（可能走了备选）
        for action in HotkeyAction.allCases {
            if let effective = hotkeyManager.spec(for: action), effective != specs[action] {
                appState.updateSettings { $0.hotkeys[action] = effective }
            }
        }
        if !failures.isEmpty {
            let names = failures.keys.map { $0.displayName }.joined(separator: "、")
            appState.showToast("快捷键注册失败：\(names)（可能被其他应用占用，可在设置中更换）")
        }
    }

    // MARK: 截图入口（权限前置检查）

    private func startRegionCapture() {
        guard ensureScreenPermission() else { return }
        let decorated = appState.settings.captureDecoration
        Task { await overlayController.beginRegionCapture(decorated: decorated) }
    }

    private func startFullscreenCapture() {
        guard ensureScreenPermission() else { return }
        Task {
            let displayID = ScreenCapture.displayUnderCursor()
            do {
                let image = try await ScreenCapture.captureDisplay(displayID)
                DispatchQueue.main.async {
                    self.handleCaptureResult(OverlayController.Result(
                        image: image,
                        globalRect: .zero,
                        displayID: displayID,
                        action: .copy
                    ))
                }
            } catch {
                appState.showToast("全屏截图失败：\(error.localizedDescription)")
            }
        }
    }

    /// 未授权屏幕录制 → 打开面板引导（功能置灰 + 打开系统设置，设计方案 §6）
    private func ensureScreenPermission() -> Bool {
        appState.refreshPermissions()
        if appState.screenPermission { return true }
        appState.showPermissionGuide = true
        panelController.showPanel()
        return false
    }

    // MARK: 截图结果（复制/保存/贴图 三出口，全部进历史流 —— 数据融合点）

    private func handleCaptureResult(_ result: OverlayController.Result?) {
        guard let result else { return }
        guard let png = ImageKit.pngData(result.image) else {
            appState.showToast("截图编码失败")
            return
        }
        switch result.action {
        case .copy:
            ClipboardWriter.writeImagePNG(png)
            historyStore.recordImage(pngData: png, source: .screenshot, kind: .screenshot)

        case .save:
            let url = PinWindowController.defaultSaveURL()
            do {
                try png.write(to: url)
                historyStore.recordImage(pngData: png, source: .screenshot, kind: .screenshot)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                appState.showToast("已保存到桌面")
            } catch {
                appState.showToast("保存失败：\(error.localizedDescription)")
            }

        case .pin:
            let outcome = pinController.pin(cgImage: result.image)
            if outcome == .ok {
                historyStore.recordImage(pngData: png, source: .screenshot, kind: .screenshot)
            }
        }
    }

    // MARK: 贴图（F3）：剪贴板当前图 → 浮窗；无图则贴历史最新一张

    private func pinFromClipboard() {
        if let png = ClipboardReader.currentImagePNG() {
            pinController.pin(pngData: png)
            return
        }
        if let latest = historyStore.latestImageItem(), let path = latest.mediaPath {
            let outcome = pinController.pin(fileAtPath: path)
            if outcome == .limitReached {
                appState.showToast("最多同时贴 \(appState.settings.pinLimit) 张贴图")
            }
            return
        }
        appState.showToast("剪贴板里没有图片可贴")
    }
}
