import AppKit
import Observation
import SwiftUI

/// 贴图浮窗池（设计方案 §3.3 贴图浮窗）：
/// 无边框置顶 NSPanel · 拖动移动 · 滚轮缩放（以光标为中心）· ⌘+滚轮调透明度 · 全空间可见
/// · Esc 关闭光标下贴图 · 悬停取色 · 点击穿透 · 重启恢复 · 上限 settings.pinLimit
@MainActor
final class PinWindowController {
    private(set) var pins: [PinPanel] = []
    weak var appState: AppState?
    private var cascadeIndex = 0
    private var escMonitor: Any?

    // MARK: 贴图入口

    /// 从 PNG 数据贴图
    @discardableResult
    func pin(pngData: Data) -> PinRequestResult {
        guard let cg = ImageKit.cgImage(from: pngData) else { return .notImage }
        return pin(cgImage: cg)
    }

    /// 从媒体文件贴图（历史条目 / 图片文件 / 恢复）
    @discardableResult
    func pin(fileAtPath path: String, restoreFrame: CGRect? = nil) -> PinRequestResult {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let cg = ImageKit.cgImage(from: data) else { return .notImage }
        return pin(cgImage: cg, restoreFrame: restoreFrame)
    }

    @discardableResult
    func pin(cgImage cg: CGImage, restoreFrame: CGRect? = nil) -> PinRequestResult {
        let settings = appState?.settings ?? AppSettings()
        if restoreFrame == nil, pins.count >= settings.pinLimit {
            appState?.showToast("最多同时贴 \(settings.pinLimit) 张贴图")
            return .limitReached
        }

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pixelSize = CGSize(width: cg.width, height: cg.height)
        let natural = CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale)

        // 初始尺寸：贴图自然大小，超屏则缩到可视区 80%
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var size = restoreFrame?.size ?? natural
        let maxW = visible.width * 0.8
        let maxH = visible.height * 0.8
        if size.width > maxW || size.height > maxH {
            let ratio = min(maxW / size.width, maxH / size.height)
            size = CGSize(width: size.width * ratio, height: size.height * ratio)
        }

        // 瀑布式排布（从右上向左下）；恢复的贴图用记录的位置
        let origin: CGPoint
        if let restoreFrame {
            origin = restoreFrame.origin
        } else {
            cascadeIndex = (cascadeIndex + 1) % 8
            let cascadeX = CGFloat(cascadeIndex) * 28
            let cascadeY = CGFloat(cascadeIndex) * 24
            origin = CGPoint(
                x: visible.maxX - size.width - 40 - cascadeX,
                y: visible.maxY - size.height - 60 - cascadeY
            )
        }

        let image = NSImage(cgImage: cg, size: natural)
        let panel = PinPanel(image: image, baseSize: natural)
        panel.controller = self
        let frame = CGRect(origin: origin, size: size)
        panel.setFrame(frame, display: true)
        configure(panel)
        pins.append(panel)
        panel.orderFront(nil)
        installEscMonitorIfNeeded()
        saveState()
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
        escMonitorTearDownIfNeeded()
        saveState()
    }

    func closeAll() {
        for panel in pins { panel.orderOut(nil) }
        pins.removeAll()
        escMonitorTearDownIfNeeded()
        saveState()
    }

    // MARK: Esc 关闭（光标下优先，否则最新一张）

    private func installEscMonitorIfNeeded() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, !self.pins.isEmpty else { return event }
            let mouse = NSEvent.mouseLocation
            let target = self.pins.last(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? self.pins.last
            if let target { self.close(target) }
            return nil
        }
    }

    private func escMonitorTearDownIfNeeded() {
        guard pins.isEmpty, let escMonitor else { return }
        NSEvent.removeMonitor(escMonitor)
        self.escMonitor = nil
    }

    // MARK: 重启恢复

    struct PinnedWindowState: Codable {
        let path: String
        let x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat
    }

    func saveState() {
        guard appState?.settings.restorePins == true else { return }
        let list = pins.compactMap { panel -> PinnedWindowState? in
            guard let path = panel.sourcePath else { return nil }
            let f = panel.frame
            return PinnedWindowState(path: path, x: f.minX, y: f.minY, width: f.width, height: f.height)
        }
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: Paths.pinsURL, options: .atomic)
        }
    }

    func restoreState() {
        guard appState?.settings.restorePins == true,
              let data = try? Data(contentsOf: Paths.pinsURL),
              let list = try? JSONDecoder().decode([PinnedWindowState].self, from: data),
              !list.isEmpty else { return }
        for w in list.prefix(6) where FileManager.default.fileExists(atPath: w.path) {
            let frame = CGRect(x: w.x, y: w.y, width: w.width, height: w.height)
            if pin(fileAtPath: w.path, restoreFrame: frame) != .ok { break }
        }
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
        // 保存目录跟随设置（默认桌面）
        var dir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        if let custom = appState?.settings.saveDir {
            let expanded = (custom as NSString).expandingTildeInPath
            if !expanded.isEmpty {
                dir = URL(fileURLWithPath: expanded, isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
        let url = Self.defaultSaveURL(in: dir)
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

    static func defaultSaveURL(in directory: URL) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return directory.appendingPathComponent("PinClip \(formatter.string(from: Date())).png")
    }

    /// 菜单：调整透明度
    func setOpacity(_ panel: PinPanel, _ value: CGFloat) {
        panel.animator().alphaValue = value
    }
}

/// 贴图面板：滚轮缩放（以光标为中心）/透明度、拖动、双击菜单、⌘单击取色
@MainActor
final class PinPanel: NSPanel {
    let baseSize: CGSize          // point 尺寸（zoom=1）
    var zoom: CGFloat = 1
    weak var controller: PinWindowController?
    let imageView: PinColorImageView
    var sourcePath: String?
    /// 悬停取色结果（⌘单击复制）
    var hoverColorHex: String?

    init(image: NSImage, baseSize: CGSize) {
        self.baseSize = baseSize
        let view = PinColorImageView(frame: NSRect(origin: .zero, size: baseSize))
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        view.autoresizingMask = [.width, .height]
        self.imageView = view
        super.init(contentRect: NSRect(origin: .zero, size: baseSize),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        contentView = view
        view.onColor = { [weak self] hex in
            self?.hoverColorHex = hex
            self?.updateColorBadge(hex)
        }
    }

    override var canBecomeKey: Bool { true }

    // MARK: 滚轮：缩放（以光标为中心）；⌘+滚轮：透明度

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

        let mouse = event.locationInWindow   // 窗口坐标（本窗口即 key 目标）
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
        // 以光标为锚点缩放：光标下的图像点缩放前后保持不动
        let rx = oldFrame.width > 0 ? (mouse.x - oldFrame.minX) / oldFrame.width : 0.5
        let ry = oldFrame.height > 0 ? (mouse.y - oldFrame.minY) / oldFrame.height : 0.5
        let newOrigin = CGPoint(x: mouse.x - rx * size.width, y: mouse.y - ry * size.height)
        setFrame(CGRect(origin: newOrigin, size: size), display: true, animate: false)
    }

    // MARK: 鼠标：⌘单击取色 / 拖动 / 双击菜单

    override func mouseDown(with event: NSEvent) {
        // ⌘单击：复制悬停色值（需开启贴图取色）
        if event.modifierFlags.contains(.command),
           controller?.appState?.settings.pinShowColor == true,
           let hex = hoverColorHex {
            ClipboardWriter.writeText(hex)
            controller?.appState?.showToast("已复制色值 \(hex)")
            return
        }
        if event.clickCount >= 2 {
            controller?.showMenu(for: self, at: NSEvent.mouseLocation)
        } else {
            performDrag(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.showMenu(for: self, at: NSEvent.mouseLocation)
    }

    // MARK: 取色徽标

    private var colorBadge: NSTextField?

    private func updateColorBadge(_ hex: String?) {
        let pinShowColor = controller?.appState?.settings.pinShowColor ?? true
        guard pinShowColor, let hex else {
            colorBadge?.removeFromSuperview()
            colorBadge = nil
            return
        }
        if colorBadge == nil {
            let label = NSTextField(labelWithString: "")
            label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
            label.textColor = .white
            label.wantsLayer = true
            label.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
            label.layer?.cornerRadius = 4
            label.isEditable = false
            label.isBordered = false
            label.autoresizingMask = [.maxXMargin, .minYMargin] // 锚定左下
            imageView.addSubview(label)
            colorBadge = label
        }
        colorBadge?.stringValue = " \(hex) ⌘复制 "
        colorBadge?.sizeToFit()
        colorBadge?.frame.origin = CGPoint(x: 8, y: imageView.bounds.height - (colorBadge?.frame.height ?? 18) - 8)
    }
}

/// 支持悬停取色的图片视图
final class PinColorImageView: NSImageView {
    var onColor: ((String?) -> Void)?
    private var rep: NSBitmapImageRep?
    private var tracking: NSTrackingArea?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if rep == nil, window != nil, let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            rep = NSBitmapImageRep(cgImage: cg)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        sampleColor(atViewPoint: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        sampleColor(atViewPoint: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        onColor?(nil)
    }

    private func sampleColor(atViewPoint p: CGPoint) {
        guard let rep else { onColor?(nil); return }
        // 视图坐标 → 图像像素（scaleProportionallyUpOrDown 居中绘制）
        let iw = rep.pixelsWide, ih = rep.pixelsHigh
        guard iw > 0, ih > 0, bounds.width > 0, bounds.height > 0 else { onColor?(nil); return }
        let s = max(bounds.width / CGFloat(iw), bounds.height / CGFloat(ih))
        let dw = CGFloat(iw) * s, dh = CGFloat(ih) * s
        let ox = (bounds.width - dw) / 2
        let oy = (bounds.height - dh) / 2
        let ix = Int((p.x - ox) / s)
        let iy = Int((p.y - oy) / s)
        guard ix >= 0, iy >= 0, ix < iw, iy < ih, let c = rep.colorAt(x: ix, y: iy) else {
            onColor?(nil)
            return
        }
        let rgb = c.usingColorSpace(.sRGB) ?? c
        onColor?(String(format: "#%02X%02X%02X",
                        Int((rgb.redComponent * 255).rounded()),
                        Int((rgb.greenComponent * 255).rounded()),
                        Int((rgb.blueComponent * 255).rounded())))
    }
}

// MARK: - 双击/右键菜单

@MainActor
extension PinWindowController {

    func showMenu(for panel: PinPanel, at screenLocation: CGPoint) {
        let menu = NSMenu()
        let target = MenuTarget(controller: self, panel: panel)
        menu.addItem(Self.item("复制图片", symbol: "doc.on.doc") { target.doCopy() })
        menu.addItem(Self.item("保存（跟随设置目录）", symbol: "square.and.arrow.down") { target.doSave() })
        let opacityMenu = NSMenu()
        for v in [0.25, 0.5, 0.75, 1.0] {
            opacityMenu.addItem(Self.item("\(Int(v * 100))%") { target.doOpacity(v) })
        }
        let opacityItem = NSMenuItem(title: "透明度", action: nil, keyEquivalent: "")
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)
        let clickThroughTitle = panel.ignoresMouseEvents ? "取消点击穿透" : "点击穿透（鼠标穿过贴图）"
        menu.addItem(Self.item(clickThroughTitle, symbol: "arrow.down.right.and.arrow.up.left") { target.doToggleClickThrough() })
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

    func doToggleClickThrough() {
        guard let panel else { return }
        panel.ignoresMouseEvents.toggle()
        // 穿透后本菜单无法再操作该贴图；从托盘「关闭全部贴图」或 Esc（对未穿透贴图）恢复
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
