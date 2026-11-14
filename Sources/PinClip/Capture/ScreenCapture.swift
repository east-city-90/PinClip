import AppKit
import CoreGraphics
import ScreenCaptureKit

/// 屏幕捕获：ScreenCaptureKit 主路径（设计方案 §5.3），CGDisplayCreateImage 兜底
enum ScreenCapture {

    enum CaptureError: LocalizedError {
        case noDisplay
        case noImage

        var errorDescription: String? {
            switch self {
            case .noDisplay: return "未找到目标显示器"
            case .noImage: return "屏幕捕获失败（请检查屏幕录制权限）"
            }
        }
    }

    // MARK: 权限（TCC Screen Recording）

    static func preflightGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 触发系统授权弹窗（仅首次），随后调用方用 preflight 复检
    static func requestPermission() async {
        _ = CGRequestScreenCaptureAccess()
        // CGRequestScreenCaptureAccess 立即返回；给系统一点时间记录授权状态
        try? await Task.sleep(nanoseconds: 800_000_000)
    }

    // MARK: 捕获

    /// 捕获整块显示器（Retina 返回物理像素分辨率）
    /// 实测：SCScreenshotManager 静态截屏在本机偶发全黑帧；CGDisplayCreateImage
    /// （deprecated 但稳定）作为静态截图主路径，SCK 保留为兜底。
    static func captureDisplay(_ displayID: CGDirectDisplayID) async throws -> CGImage {
        if let image = CGDisplayCreateImage(displayID) {
            return image
        }
        if let image = try? await captureViaSCK(displayID) {
            return image
        }
        throw CaptureError.noImage
    }

    /// 光标所在显示器
    static func displayUnderCursor() -> CGDirectDisplayID {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        return displayID(of: screen) ?? CGMainDisplayID()
    }

    /// 全部屏上显示器（含各自 backing scale）
    static func screensWithIDs() -> [(screen: NSScreen, displayID: CGDirectDisplayID)] {
        NSScreen.screens.compactMap { screen in
            guard let id = displayID(of: screen) else { return nil }
            return (screen, id)
        }
    }

    static func displayID(of screen: NSScreen?) -> CGDirectDisplayID? {
        guard let screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    static func backingScale(of displayID: CGDirectDisplayID) -> CGFloat {
        for screen in NSScreen.screens where Self.displayID(of: screen) == displayID {
            return screen.backingScaleFactor
        }
        return 2.0
    }

    // MARK: SCK 实现

    private static func captureViaSCK(_ displayID: CGDirectDisplayID) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let scale = backingScale(of: displayID)
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = false
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
