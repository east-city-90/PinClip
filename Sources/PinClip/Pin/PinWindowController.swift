import AppKit
import Observation
import SwiftUI

/// 贴图浮窗池（设计方案 §3.3 贴图浮窗）：
/// 无边框置顶 NSPanel · 拖动移动 · 滚轮缩放 · ⌘+滚轮调透明度 · 全空间可见 · 双击菜单 · 免费限 3 张
@MainActor
final class PinWindowController {
    private(set) var pins: [PinPanel] = []
    weak var appState: AppState?
    private var cascadeIndex = 0

    /// 从 PNG 数据贴图
    @discardableResult
    func pin(pngData: Data) -> PinRequestResult {
        guard let cg = ImageKit.cgImage(from: pngData) else { return .notImage }
        return pin(cgImage: cg)
    }

    /// 从媒体文件贴图（历史条目）
    @discardableResult
    func pin(fileAtPath path: String) -> PinRequestResult {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let cg = ImageKit.cgImage(from: data) else { return .notImage }
        return pin(cgImage: cg)
    }

    @discardableResult
    func pin(cgImage cg: CGImage) -> PinRequestResult {
        let settings = appState?.settings ?? AppSettings()
        if pins.count >= settings.pinLimit {
            appState?.showToast("最多同时贴 \(settings.pinLimit) 张贴图")
            return .limitReached
        }

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pixelSize = CGSize(width: cg.width, height: cg.height)
        let natural = CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale)

        // 初始尺寸：贴图自然大小，超屏则缩到可视区 80%
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var size = natural
        let maxW = visible.width * 0.8
        let maxH = visible.height * 0.8
        if size.width > maxW || size.height > maxH {
            let ratio = min(maxW / size.width, maxH / size.height)
            size = CGSize(width: size.width * ratio, height: size.height * ratio)
        }

        // 瀑布式排布（从右上向左下）
        cascadeIndex = (cascadeIndex + 1) % 8
        let cascadeX = CGFloat(cascadeIndex) * 28
        let cascadeY = CGFloat(cascadeIndex) * 24
        let origin = CGPoint(
            x: visible.maxX - size.width - 40 - cascadeX,
            y: visible.maxY - size.height - 60 - cascadeY
        )

        let image = NSImage(cgImage: cg, size: natural)
        let panel = PinPanel(image: image, baseSize: natural)
        panel.controller = self
        let frame = CGRect(origin: origin, size: size)
        panel.setFrame(frame, display: true)
        configure(panel)
        pins.append(panel)
        panel.orderFront(nil)
        return .ok
    }

    private func configure(_ panel: PinPanel) {
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovable = true
    }

    func close(_ panel: PinPanel) {
        panel.orderOut(nil)
        pins.removeAll { $0 === panel }
    }

    func closeAll() {
        for panel in pins { panel.orderOut(nil) }
        pins.removeAll()
    }

    // MARK: 双击菜单动作

    func copyPin(_ panel: PinPanel) {
        guard let image = panel.imageView.image, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        ClipboardWriter.writeImagePNG(png)
    }

    @discardableResult
    func savePin(_ panel: PinPanel) -> String? {
        guard let image = panel.imageView.image, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = Self.defaultSaveURL()
        do {
            try png.write(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            appState?.showToast("已保存：\(url.lastPathComponent)")
            return url.path
        } catch {
            appState?.showToast("保存失败：\(error.localizedDescription)")
            return nil
        }
    }

    static func defaultSaveURL() -> URL {
        let dir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return dir.appendingPathComponent("PinClip \(formatter.string(from: Date())).png")
    }

    /// 菜单：调整透明度
    func setOpacity(_ panel: PinPanel, _ value: CGFloat) {
        panel.animator().alphaValue = value
    }
}

/// 贴图面板：滚轮缩放/透明度、拖动、双击菜单
@MainActor
final class PinPanel: NSPanel {
    let baseSize: CGSize          // point 尺寸（zoom=1）
    var zoom: CGFloat = 1
    weak var controller: PinWindowController?
    let imageView: NSImageView

    init(image: NSImage, baseSize: CGSize) {
        self.baseSize = baseSize
        let view = NSImageView(frame: NSRect(origin: .zero, size: baseSize))
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        view.autoresizingMask = [.width, .height]
        self.imageView = view
        super.init(contentRect: NSRect(origin: .zero, size: baseSize),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        contentView = view
    }

    override var canBecomeKey: Bool { true }

    // MARK: 滚轮：缩放（以中心为基准）；⌘+滚轮：透明度

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let delta = event.scrollingDeltaY / 12
            alphaValue = min(max(alphaValue + delta, 0.15), 1)
            return
        }
        let factor = event.scrollingDeltaY > 0 ? 1.1 : 1 / 1.1
        let newZoom = min(max(zoom * factor, 0.15), 4)
        guard abs(newZoom - zoom) > 0.001 else { return }
        zoom = newZoom

        let oldFrame = frame
        var size = CGSize(width: baseSize.width * zoom, height: baseSize.height * zoom)
        // 尺寸边界：60pt 最小 / 不超过当前屏可视区
        let screen = NSScreen.screens.first { $0.frame.intersects(oldFrame) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            size.width = min(size.width, visible.width * 0.95)
            size.height = min(size.height, visible.height * 0.95)
        }
        size.width = max(size.width, 60)
        size.height = max(size.height, 60)
        let center = CGPoint(x: oldFrame.midX, y: oldFrame.midY)
        let newFrame = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                              width: size.width, height: size.height)
        setFrame(newFrame, display: true, animate: false)
    }

    // MARK: 鼠标：单击拖动 / 双击菜单

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            controller?.showMenu(for: self, at: NSEvent.mouseLocation)
        } else {
            performDrag(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.showMenu(for: self, at: NSEvent.mouseLocation)
    }
}

// MARK: - 双击/右键菜单

@MainActor
extension PinWindowController {

    func showMenu(for panel: PinPanel, at screenLocation: CGPoint) {
        let menu = NSMenu()
        let target = MenuTarget(controller: self, panel: panel)
        menu.addItem(Self.item("复制图片", symbol: "doc.on.doc") { target.doCopy() })
        menu.addItem(Self.item("保存到桌面", symbol: "square.and.arrow.down") { target.doSave() })
        let opacityMenu = NSMenu()
        for v in [0.25, 0.5, 0.75, 1.0] {
            opacityMenu.addItem(Self.item("\(Int(v * 100))%") { target.doOpacity(v) })
        }
        let opacityItem = NSMenuItem(title: "透明度", action: nil, keyEquivalent: "")
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)
        menu.addItem(.separator())
        menu.addItem(Self.item("关闭贴图", symbol: "xmark") { target.doCloseOne() })
        menu.addItem(Self.item("关闭全部贴图", symbol: "xmark.circle") { target.doCloseAll() })
        menu.popUp(positioning: nil, at: screenLocation, in: nil)
        // popUp 异步返回，target 需要存活到动作执行：作为菜单对象持有
        menu.delegate = target
    }

    private static func item(_ title: String, symbol: String? = nil, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuTarget.invoke(_:)), keyEquivalent: "")
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        }
        let target = MenuTarget(controller: nil, panel: nil)
        target.handler = action
        item.representedObject = target
        item.target = target
        return item
    }
}

/// 菜单项动作分发器（闭包桥接）
@MainActor
final class MenuTarget: NSObject, NSMenuDelegate {
    weak var controller: PinWindowController?
    weak var panel: PinPanel?
    @objc var handler: (() -> Void)?

    init(controller: PinWindowController?, panel: PinPanel?) {
        self.controller = controller
        self.panel = panel
    }

    @objc func invoke(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuTarget)?.handler?()
    }

    func doCopy() {
        guard let controller, let panel else { return }
        controller.copyPin(panel)
    }

    func doSave() {
        guard let controller, let panel else { return }
        _ = controller.savePin(panel)
    }

    func doOpacity(_ v: CGFloat) {
        guard let controller, let panel else { return }
        controller.setOpacity(panel, v)
    }

    func doCloseOne() {
        guard let controller, let panel else { return }
        controller.close(panel)
    }

    func doCloseAll() {
        guard let controller else { return }
        controller.closeAll()
    }
}
