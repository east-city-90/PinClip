import AppKit
import SwiftUI

/// 历史面板：非激活 NSPanel（呼出不抢原 App 焦点，自动粘贴无需重新激活）
@MainActor
final class PanelController: NSObject, NSWindowDelegate, PanelActions {
    private let panel: PanelPanel
    /// 失焦收起的抑制开关：showPanel 内部的 orderOut 会触发一次 resignKey，不能被当成用户点走
    private var resignSuppress = false
    private let settingsStore: SettingsStore
    let panelVM: PanelVM
    private weak var appState: AppState?
    private weak var store: HistoryStore?
    private weak var pinController: PinWindowController?
    private weak var settingsWindow: SettingsWindowController?
    /// 历史图片「标注」复用截图遮罩
    weak var overlay: OverlayController?

    init(appState: AppState,
         store: HistoryStore,
         pinController: PinWindowController,
         settingsWindow: SettingsWindowController) {
        self.appState = appState
        self.store = store
        self.settingsStore = appState.settingsStore
        self.pinController = pinController
        self.settingsWindow = settingsWindow
        self.panelVM = PanelVM(store: store, appState: appState)

        let width: CGFloat = 720
        let height: CGFloat = 560
        panel = PanelPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        super.init()
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: PanelRootView(appState: appState, actions: self, vm: panelVM))
    }

    var panelWindow: NSPanel { panel }

    // MARK: 显示/隐藏

    func togglePanel() {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    func showPanel() {
        NSLog("PinClip.panel: showPanel visibleBefore=\(panel.isVisible)")
        appState?.refreshPermissions()
        resignSuppress = true
        // 先隐藏再定位：显示模式重排后，服务端合成位置可能与 NSWindow 坐标脱节（0.9 倍缩放残留），
        // 相同 frame 的 setFrame 会被当 no-op 跳过；orderOut 强制下一次显示采用新 frame
        panel.orderOut(nil)
        positionNearCursor()
        panel.makeKeyAndOrderFront(nil)
        positionNearCursor()
        resignSuppress = false
        NotificationCenter.default.post(name: .pinclipPanelShown, object: nil)
    }

    func hidePanel() {
        guard panel.isVisible else { return }
        NSLog("PinClip.panel: hidePanel（失焦或主动收起）")
        panel.orderOut(nil)
    }

    /// 光标所在屏，面板统一居中偏上（用户偏好；引导页与历史面板同规则）
    /// 注意：不用 visibleFrame——显示模式切换后 App 内 NSScreen 缓存可能陈旧，
    /// 曾导致面板被钳制成 648×504（0.9 倍）
    private func positionNearCursor() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let width = min(720, max(360, screen.frame.width - 24))
        let height = min(560, max(320, screen.frame.height - 80))
        let frame = CGRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.midY - height / 2 + 30,
            width: width,
            height: height
        )
        panel.setFrame(frame, display: true)
    }

    // MARK: 失焦自动收起（弹层语义）

    nonisolated func windowDidResignKey(_ notification: Notification) {
        let suppressed = MainActor.assumeIsolated { resignSuppress }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !suppressed else { return }
                self.hidePanel()
            }
        }
    }

    // MARK: PanelActions

    func activate(_ item: ClipItem, paste: Bool) {
        ClipboardWriter.writeItem(item)
        store?.bump(id: item.id)
        hidePanel()

        let settings = settingsStore.settings
        guard paste, settings.autoPaste else { return }
        if AutoPaste.isProcessTrusted(prompt: false) {
            AutoPaste.postCommandV(delayMs: settings.autoPasteDelayMs)
        } else {
            // 未授权：首次触发系统授权引导，此后仅复制
            AutoPaste.isProcessTrusted(prompt: true)
            appState?.showToast("已复制 · 授予辅助功能权限后可自动粘贴")
        }
    }

    func copyPlain(_ item: ClipItem) {
        guard let text = item.textContent else { return }
        ClipboardWriter.writeText(text)
        store?.bump(id: item.id)
        hidePanel()
    }

    func togglePin(_ item: ClipItem) {
        _ = store?.togglePin(id: item.id)
    }

    func delete(_ item: ClipItem) {
        store?.delete(id: item.id)
    }

    func pinToScreen(_ item: ClipItem) -> PinRequestResult {
        hidePanel()
        guard let path = item.displayImagePath else { return .notImage }
        return pinController?.pin(fileAtPath: path) ?? .notImage
    }

    /// 历史图片 → 重新标注（复用截图遮罩，编辑后走复制/保存/贴图出口）
    func annotate(_ item: ClipItem) {
        hidePanel()
        guard let path = item.displayImagePath else { return }
        Task { [weak self] in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let cg = ImageKit.cgImage(from: data) else {
                await MainActor.run { self?.appState?.showToast("图片读取失败") }
                return
            }
            self?.overlay?.beginAnnotateExisting(cg)
        }
    }

    func openSettings() {
        hidePanel()
        settingsWindow?.show()
    }

    func dismissOnboarding() {
        appState?.updateSettings { $0.firstRunDone = true }
        appState?.showPermissionGuide = false
    }
}

/// 面板根视图：权限引导 ↔ 历史面板切换（Liquid Glass 玻璃底 + 圆角，窗口本身透明）
struct PanelRootView: View {
    let appState: AppState
    let actions: any PanelActions
    let vm: PanelVM

    var body: some View {
        Group {
            if !appState.settings.firstRunDone || appState.showPermissionGuide {
                OnboardingView(appState: appState, actions: actions)
            } else {
                HistoryPanelView(vm: vm, appState: appState, actions: actions)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .tint(Theme.accent)
    }
}

/// 无边框面板需要显式声明可成为 key window（接收键盘输入）
final class PanelPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

extension Notification.Name {
    static let pinclipPanelShown = Notification.Name("pinclip.panel.shown")
}
