import AppKit
import CoreGraphics

/// 窗口吸附数据源：CGWindowList 拿屏上窗口 frame（设计方案 §5.3）
enum SnapWindows {

    /// 屏上普通窗口列表（排除自身进程、桌面/系统层、零尺寸）。
    /// 坐标：全局屏幕空间，左上原点，单位 point（与 CGWindowList 一致）。
    static func list(excludingPID pid: pid_t) -> [SnapWindow] {
        let opts = CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements])
        guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var result: [SnapWindow] = []
        for dict in raw {
            let layer = (dict[kCGWindowLayer as String] as? NSNumber)?.int32Value ?? -1
            guard layer == 0 else { continue }
            let ownerPID = (dict[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            guard ownerPID != pid else { continue }
            // 有屏幕录制权限才能拿到 kCGWindowName；拿不到就只用 ownerName
            let title = dict[kCGWindowName as String] as? String ?? ""
            let appName = dict[kCGWindowOwnerName as String] as? String ?? ""
            guard !appName.isEmpty else { continue }

            var frame = CGRect.zero
            if let bounds = dict[kCGWindowBounds as String] as? [String: Any] {
                CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary, &frame)
            }
            guard frame.width >= 40, frame.height >= 40 else { continue }
            // 全屏铺满的窗口（wallpaper 类）不参与吸附
            if frame.width >= maxScreenWidth(), frame.height >= maxScreenHeight() { continue }

            let winID = (dict[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? UInt32(result.count)
            result.append(SnapWindow(id: winID, title: title, appName: appName, rect: frame))
        }
        return result
    }

    private static func maxScreenWidth() -> CGFloat {
        NSScreen.screens.map { $0.frame.width }.max() ?? 0
    }

    private static func maxScreenHeight() -> CGFloat {
        NSScreen.screens.map { $0.frame.height }.max() ?? 0
    }

    /// 查询本进程指定窗口的实际合成 frame（CGWindow 全局左上坐标，point）
    /// 用于绕开 NSWindow.frame 与窗口服务合成位置的偏差（显示模式重排 0.9 倍等）
    static func actualFrame(pid: pid_t, minWidth: CGFloat) -> CGRect? {
        let opts = CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements])
        guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return nil }
        var best: CGRect?
        for dict in raw {
            let ownerPID = (dict[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1
            guard ownerPID == pid else { continue }
            var frame = CGRect.zero
            if let b = dict[kCGWindowBounds as String] as? [String: Any] {
                CGRectMakeWithDictionaryRepresentation(b as CFDictionary, &frame)
            }
            guard frame.width >= minWidth, frame.height >= 100 else { continue }
            if best == nil || frame.width > best!.width { best = frame }
        }
        return best
    }
}
