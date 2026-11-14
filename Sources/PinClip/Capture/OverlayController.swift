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

    private var windows: [OverlayWindow] = []
    private var states: [DisplayCaptureState] = []
    private var keyMonitor: Any?
    private var finished = false
    private var cursorPushed = false
    private(set) var isRunning = false

    // MARK: 启动

    func beginRegionCapture(decorated: Bool = false) async {
        guard !isRunning else { return }
        isRunning = true
        finished = false

        let snaps = SnapWindows.list(excludingPID: ProcessInfo.processInfo.processIdentifier)
        let cursorDisplay = ScreenCapture.displayUnderCursor()

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
            state.decorated = decorated
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
        installKeyMonitor()
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
}
