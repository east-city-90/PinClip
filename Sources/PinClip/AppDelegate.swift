import AppKit
import SwiftUI
import UserNotifications

/// 应用组装与调度中枢：热键 → 截图/面板/贴图 流程编排
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settingsStore: SettingsStore
    let appState: AppState
    let historyStore: HistoryStore
    let clipboardMonitor: ClipboardMonitor
    let androidSync = AndroidSyncService()
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
            delayedRegionCapture: { [weak self] in self?.startDelayedRegionCapture() },
            fullscreenCapture: { [weak self] in self?.startFullscreenCapture() },
            togglePanel: { [weak self] in self?.panelController.togglePanel() },
            pinFromClipboard: { [weak self] in self?.pinFromClipboard() },
            pastePlainText: { [weak self] in self?.pastePlainText() },
            checkUpdates: { [weak self] in
                guard let self else { return }
                Task { await UpdateChecker.checkManual(appState: self.appState) }
            },
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
        appState.androidSync = androidSync
        clipboardMonitor.androidSync = androidSync
        androidSync.store = historyStore
        androidSync.appState = appState
        pinController.appState = appState
        overlayController.appState = appState
        overlayController.onResult = { [weak self] result in
            self?.handleCaptureResult(result)
        }
        // 历史图片「标注」→ 截图遮罩
        panelController.overlay = overlayController
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = statusItem // 触发 lazy 创建：菜单栏图标必须在启动时挂上
        installDebugNotifyIfDebug()
        registerHotkeys()
        clipboardMonitor.start()
        historyStore.startRetentionLoop(settingsProvider: { [weak appState] in
            appState?.settings ?? AppSettings()
        })

        // 外观三态（system / light / dark）
        AppAppearance.apply(appState.settings.appearance)

        // 重启恢复贴图
        pinController.restoreState()

        // 首启/权限缺失 → 面板展示引导（设计方案 §6 权限引导）
        appState.refreshPermissions()
        if historyStore.degraded {
            appState.showToast("历史库损坏已重置（旧数据备份于 Application Support）")
        }
        if !appState.screenPermission || !appState.settings.firstRunDone {
            panelController.showPanel()
        }

        // 静默检查更新（每天至多一次，可在设置关闭）
        UpdateChecker.autoCheckIfNeeded(appState: appState)
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardMonitor.stop()
        pinController.saveState()
        androidSync.shutdown()
    }

    // MARK: 开发调试信号（仅 DEBUG 构建；release 不注册任何 Darwin 通知监听）

    private var debugNotifyInstalled = false

    private func installDebugNotifyIfDebug() {
        #if DEBUG
        guard !debugNotifyInstalled else { return }
        debugNotifyInstalled = true
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        // Darwin 通知中心必须显式注册每个通知名（name=nil 观察全部不生效）
        for signal in ["pinclip.debugshot", "pinclip.debugsettings", "pinclip.debugcapture",
                       "pinclip.debugcancel", "pinclip.rendershot"] {
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
        #endif
    }

    #if DEBUG
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
        case "pinclip.rendershot":
            renderDebugShots()
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
                        NSLog("PinClip.debug: display \(displayID) 面板裁剪 -> /tmp/pinclip-ui-crop.png (\(png.count) bytes)")
                    }
                } catch {
                    NSLog("PinClip.debug: display \(displayID) 截屏失败 \(error)")
                }
            }
        }
    }

    /// 离屏渲染自检（不依赖屏幕录制权限/屏幕内容）：面板与设置页在明暗两套外观下的位图 → /tmp
    private func renderDebugShots() {
        func render(_ name: String, appearance: NSAppearance.Name, colorScheme: ColorScheme,
                    width: CGFloat, height: CGFloat, makeView: () -> NSView) {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            win.appearance = NSAppearance(named: appearance)
            win.isReleasedWhenClosed = false
            let host = makeView()
            host.frame = NSRect(origin: .zero, size: CGSize(width: width, height: height))
            win.contentView = host
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                NSLog("PinClip.render: \(name) bitmapImageRep=nil")
                return
            }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "/tmp/pinclip-render-\(name).png"))
                NSLog("PinClip.render: \(name) \(rep.pixelsWide)×\(rep.pixelsHigh) -> /tmp/pinclip-render-\(name).png")
            }
            win.orderOut(nil)
            win.contentView = nil
        }

        let settingsVM = SettingsVM()
        for (suffix, appearance, scheme) in
            [("light", NSAppearance.Name.aqua, ColorScheme.light),
             ("dark", NSAppearance.Name.darkAqua, ColorScheme.dark)] {
            render("panel-\(suffix)", appearance: appearance, colorScheme: scheme, width: 720, height: 560) {
                NSHostingView(rootView: PanelRootView(
                    appState: appState,
                    actions: panelController,
                    vm: panelController.panelVM
                ).environment(\.colorScheme, scheme))
            }
            render("settings-\(suffix)", appearance: appearance, colorScheme: scheme, width: 720, height: 520) {
                NSHostingView(rootView: SettingsView(appState: appState, vm: settingsVM)
                    .environment(\.colorScheme, scheme))
            }
        }
    }
    #endif

    // MARK: 热键注册（冲突自动降级到备选键，设计方案 §3.2）

    private func registerHotkeys() {
        let settings = settingsStore.settings
        let specs = settings.hotkeys
        let fallbacks: [HotkeyAction: [HotkeySpec]] = [
            .region: [HotkeySpec(keyCode: 0x02, useCommand: false, useOption: true, useControl: false, useShift: false, display: "⌥D")],   // ⌥D
            .fullscreen: [HotkeySpec(keyCode: 0x14, useCommand: false, useOption: true, useControl: false, useShift: false, display: "⌥E")], // ⌥E
            .panel: [HotkeySpec(keyCode: 0x0B, useCommand: false, useOption: true, useControl: false, useShift: false, display: "⌥B")],     // ⌥B
            .pin: [HotkeySpec(keyCode: 118, useCommand: false, useOption: false, useControl: false, useShift: false, display: "F4")],      // F4
            .pastePlain: [],
            .delayedRegion: [],
        ]
        let handlers: [HotkeyAction: () -> Void] = [
            .region: { [weak self] in self?.startRegionCapture() },
            .fullscreen: { [weak self] in self?.startFullscreenCapture() },
            .panel: { [weak self] in self?.panelController.togglePanel() },
            .pin: { [weak self] in self?.pinFromClipboard() },
            .pastePlain: { [weak self] in self?.pastePlainText() },
            .delayedRegion: { [weak self] in self?.startDelayedRegionCapture() },
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
        Task { await overlayController.beginRegionCapture() }
    }

    private func startDelayedRegionCapture() {
        guard ensureScreenPermission() else { return }
        overlayController.beginDelayedRegionCapture(seconds: max(1, appState.settings.delaySeconds))
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

    // MARK: 全局纯文本粘贴（⇧⌥V）：剪贴板内容去掉格式 → 粘到前台应用

    private func pastePlainText() {
        let pb = NSPasteboard.general
        var text = pb.string(forType: .string)
        if (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // 剪贴板无文本（图片/文件）：回退到历史里最新一条文本
            text = historyStore.latestTextItem()?.textContent
        }
        guard let text, !text.isEmpty else {
            appState.showToast("没有可粘贴的文本")
            return
        }
        ClipboardWriter.writeText(text)
        let settings = appState.settings
        if AutoPaste.isProcessTrusted(prompt: false) {
            AutoPaste.postCommandV(delayMs: settings.autoPasteDelayMs)
        } else {
            AutoPaste.isProcessTrusted(prompt: true)
            appState.showToast("已转为纯文本 · 授予辅助功能权限后可自动粘贴")
        }
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
            historyStore.recordImage(png: png, tiff: nil, source: .screenshot, kind: .screenshot)

        case .save:
            let dir = URL(fileURLWithPath: (appState.settings.saveDir as NSString).expandingTildeInPath, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = PinWindowController.defaultSaveURL(in: dir)
                try png.write(to: url)
                historyStore.recordImage(png: png, tiff: nil, source: .screenshot, kind: .screenshot)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                appState.showToast("已保存：\(url.lastPathComponent)")
            } catch {
                appState.showToast("保存失败：\(error.localizedDescription)")
            }

        case .pin:
            let outcome = pinController.pin(cgImage: result.image)
            if outcome == .ok {
                historyStore.recordImage(png: png, tiff: nil, source: .screenshot, kind: .screenshot)
            }
        }
    }

    // MARK: 贴图（F3）：剪贴板当前图（位图 / 单个图片文件）→ 浮窗；无图则贴历史最新一张

    private func pinFromClipboard() {
        // 访达 ⌘C 复制的图片文件（文件 URL）也按图片对待
        if let fileURL = ClipboardReader.currentImageFileURL() {
            pinController.pin(fileAtPath: fileURL.path)
            return
        }
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
