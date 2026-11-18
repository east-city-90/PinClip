import AppKit
import SwiftUI

/// 截图会话控制器：冻结帧 → 每屏一个原生透明 NSWindow 遮罩 → 选区/标注 → 导出
/// （设计方案 §5.1 兜底路径已生效：遮罩层是原生 NSWindow，不是 WebView）
@MainActor
final class OverlayController {
    struct Result {
        let image: CGImage
        let globalRect: CGRect            // 全局左上原点，point
        let displayID: CGDirectDisplayID
        let action: CaptureAction
    }

    /// nil = 取消
    var onResult: ((Result?) -> Void)?

    weak var appState: AppState?

    private var windows: [OverlayWindow] = []
    private var states: [DisplayCaptureState] = []
    private var keyMonitor: Any?
    private var finished = false
    private var cursorPushed = false
    private(set) var isRunning = false

    // MARK: 启动

    func beginRegionCapture() async {
        guard !isRunning else { return }
        isRunning = true
        finished = false

        let settings = appState?.settings ?? AppSettings()
        let snaps = SnapWindows.list(excludingPID: ProcessInfo.processInfo.processIdentifier)
        let cursorDisplay = ScreenCapture.displayUnderCursor()
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let mouseTL = CGPoint(
            x: NSEvent.mouseLocation.x,
            y: primaryMaxY - NSEvent.mouseLocation.y
        )

        // 冻结帧：先截屏再弹遮罩（否则会截到遮罩本身）
        for (screen, displayID) in ScreenCapture.screensWithIDs() {
            guard let image = try? await ScreenCapture.captureDisplay(displayID) else { continue }
            let state = DisplayCaptureState(
                displayID: displayID,
                screen: screen,
                bgImage: image,
                scale: ScreenCapture.backingScale(of: displayID),
                snapWindows: snaps,
                isPrimaryInteraction: displayID == cursorDisplay
            )
            state.decorated = settings.captureDecoration
            state.showBadge = settings.showSizeBadge
            // 初始吸附：光标所在窗口在弹出瞬间直接高亮（无需先移动鼠标）
            if displayID == cursorDisplay,
               let hit = snaps.first(where: { $0.rect.contains(mouseTL) }) {
                state.hoverSnap = hit
            }
            states.append(state)
        }
        guard !states.isEmpty else {
            finish()
            onResult?(nil)
            return
        }
        presentWindows()
    }

    private func presentWindows() {
        NSCursor.crosshair.push()
        cursorPushed = true
        for state in states {
            let win = OverlayWindow(
                contentRect: state.screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: state.screen
            )
            win.level = .screenSaver
            win.isOpaque = false
            win.backgroundColor = .clear
            win.hasShadow = false
            win.ignoresMouseEvents = false
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            win.isReleasedWhenClosed = false
            win.contentView = NSHostingView(rootView: CaptureOverlayView(state: state, controller: self))
            if state.isPrimaryInteraction {
                win.makeKeyAndOrderFront(nil)
            } else {
                win.orderFrontRegardless()
            }
            windows.append(win)
        }
        // 关键：遮罩属于非激活应用时，首次按下会被系统当作「激活应用」吞掉（首按不投递），
        // 必须显式激活本应用，保证首次拖拽直接生效
        NSApp.activate(ignoringOtherApps: true)
        installKeyMonitor()
        startBlindDragWatch()
    }

    // MARK: 盲拖接管（用户在冻结/弹窗期间已按住鼠标拖动：首按下事件丢失的场景）

    private var blindDragTimer: Timer?

    private func startBlindDragWatch() {
        guard blindDragTimer == nil else { return }
        blindDragTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                self?.blindDragTick(timer)
            }
        }
    }

    private func blindDragTick(_ timer: Timer) {
        guard !finished, !states.isEmpty else {
            timer.invalidate(); blindDragTimer = nil; return
        }
        guard let state = states.first(where: { $0.isPrimaryInteraction }) ?? states.first,
              state.phase == .picking else {
            timer.invalidate(); blindDragTimer = nil; return
        }
        let mouse = NSEvent.mouseLocation
        guard let cursorScreen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) else { return }
        let topLeft = ScreenGeometry.screenTopLeft(of: cursorScreen)
        let point = CGPoint(x: mouse.x - topLeft.x, y: cursorScreen.frame.maxY - mouse.y)
        let leftDown = (NSEvent.pressedMouseButtons & 1) != 0   // bit0 = 左键（macOS 为 Int 位掩码）

        if leftDown {
            if state.dragStart == nil {
                state.beginDrag(at: point)   // 接管进行中的拖拽（初始吸附保留供微动采纳）
            } else {
                state.updateDrag(to: point)
            }
        } else {
            state.endDrag(at: point)
            timer.invalidate(); blindDragTimer = nil
        }
    }

    // MARK: 键盘（Esc 取消 / ⏎ 复制 / ⌘S 保存 / ⌘Z 撤销 / Esc 关闭文字草稿）

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.finished else { return event }
            // 文字输入中：Esc 仅关闭草稿，其余按键透传给输入框
            if self.states.contains(where: { $0.textDraft != nil }) {
                if event.keyCode == 53 {
                    self.states.forEach { $0.textDraft = nil }
                    return nil
                }
                if event.keyCode == 36 {
                    self.states.forEach { self.commitDraftIfAny($0) }
                    return nil
                }
                return event
            }
            switch event.keyCode {
            case 53: // Esc
                self.cancel()
                return nil
            case 36: // Enter → 复制
                self.finalize(action: .copy)
                return nil
            default:
                if event.modifierFlags.contains(.command) {
                    switch event.charactersIgnoringModifiers {
                    case "z":
                        self.states.forEach { $0.undo() }
                        return nil
                    case "s":
                        self.finalize(action: .save)
                        return nil
                    default:
                        break
                    }
                }
                return event
            }
        }
    }

    private func commitDraftIfAny(_ state: DisplayCaptureState) {
        state.commitTextDraft()
    }

    // MARK: 结束

    func finalize(action: CaptureAction) {
        guard !finished else { return }
        // 取有选区的屏（多屏时以用户正在操作的那块为准）
        guard let state = states.first(where: { $0.selection != nil }) else { return }
        // 导出前提交未完成的文字草稿
        commitDraftIfAny(state)
        guard let image = state.exportImage(action: action) else { return }
        // 装饰导出（CleanShot 式背景+阴影）
        var finalImage = image
        if state.decorated {
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == NSAppearance.Name("darkAqua")
            finalImage = ImageKit.decorated(image, scale: state.scale, dark: dark) ?? image
        }
        // 自定义水印（设置 → 通用）
        if let wmText = appState?.settings.watermarkText, !wmText.isEmpty {
            finalImage = ImageKit.watermarked(
                finalImage,
                text: wmText,
                corner: appState?.settings.watermarkCorner ?? "bottomRight",
                opacity: appState?.settings.watermarkOpacity ?? 0.55,
                scale: state.scale
            ) ?? finalImage
        }
        let rect = state.selectionGlobalRect ?? .zero
        finish()
        onResult?(Result(image: finalImage, globalRect: rect, displayID: state.displayID, action: action))
    }

    func cancel() {
        guard !finished else { return }
        finish()
        onResult?(nil)
    }

    /// 调试演示：自动框选（可指定覆盖某个全局矩形，如面板窗口），铺示例标注，保持遮罩打开
    func debugAutoSelectDemo(coveringRect: CGRect? = nil) {
        guard !finished, let state = states.first(where: { $0.isPrimaryInteraction }) ?? states.first else { return }
        let size = state.bgPointSize
        let sel: CGRect
        if let rect = coveringRect {
            // 全局左上坐标 → 该屏视图坐标（精确覆盖，无外扩：避免暗化周边泄露其他 App）
            let tl = ScreenGeometry.screenTopLeft(of: state.screen)
            sel = CGRect(
                x: max(8, rect.minX - tl.x),
                y: max(40, rect.minY - tl.y),
                width: min(rect.width, size.width - 16),
                height: min(rect.height, size.height - 16)
            )
        } else {
            sel = CGRect(
                x: size.width * 0.24, y: size.height * 0.16,
                width: size.width * 0.52, height: size.height * 0.5
            )
        }
        state.selection = sel
        state.phase = .editing
        state.tool = .none

        let red = Color(red: 239 / 255, green: 68 / 255, blue: 68 / 255)
        let blue = Color(red: 59 / 255, green: 130 / 255, blue: 246 / 255)
        let white = Color.white

        var rectStroke = Stroke(kind: .rect, color: red, width: 4)
        rectStroke.start = CGPoint(x: 24, y: 24)
        rectStroke.end = CGPoint(x: sel.width - 24, y: sel.height - 24)
        var arrowStroke = Stroke(kind: .arrow, color: blue, width: 4)
        arrowStroke.start = CGPoint(x: 40, y: 48)
        arrowStroke.end = CGPoint(x: 170, y: 140)
        var numberStroke = Stroke(kind: .number, color: red)
        numberStroke.start = CGPoint(x: 30, y: 30)
        numberStroke.number = 1
        var lineStroke = Stroke(kind: .line, color: red, width: 3)
        lineStroke.start = CGPoint(x: 180, y: 36)
        lineStroke.end = CGPoint(x: 320, y: 36)
        var textStroke = Stroke(kind: .text, color: white)
        textStroke.start = CGPoint(x: 60, y: sel.height - 64)
        textStroke.text = "PinClip 贴剪 · 微信式标注"

        state.strokes = [rectStroke, arrowStroke, numberStroke, lineStroke, textStroke]
        NSLog("PinClip.debug: demo sel=\(sel) scale=\(state.scale)")
    }

    private func finish() {
        finished = true
        isRunning = false
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        blindDragTimer?.invalidate()
        blindDragTimer = nil
        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
        for win in windows {
            win.orderOut(nil)
            win.contentView = nil
        }
        windows.removeAll()
        states.removeAll()
    }
}

/// 无边框窗口需要显式声明可成为 key window（接收键盘）
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    /// 关键修复：遮罩弹出后用户首次按下鼠标时窗口可能尚未 key，
    /// 该次按下只会「激活窗口」而不投递给视图——SwiftUI 拖拽收不到（表现为第一次拖拽不生效）。
    /// 在事件分发前先 key 化，保证首次按下即生效。
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            NSLog("PinClip.overlay: leftMouseDown isKey=\(isKeyWindow) visible=\(isVisible)")
            if !isKeyWindow { makeKey() }
        }
        super.sendEvent(event)
    }
}
