import SwiftUI
import AppKit

// MARK: - 十六进制色便捷构造

extension NSColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(
            red: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// magpie 设计令牌（实测自 yetone/magpie app.css，亮暗双套动态色）
/// 规范要点：中性色统一带 1–2% 蓝紫倾向；暗色强调色整体提亮一档；文字 5 级灰阶；
/// 字号锁 10.5–13px 工具刻度；字重 400/450/500/600。
enum Theme {
    // MARK: - 亮暗动态 helper

    private static func mag(_ light: String, _ dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let darkMode = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: darkMode ? dark : light)
        })
    }

    private static func magAlpha(_ light: Double, _ dark: Double,
                                 base lightHex: String, darkHex: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let darkMode = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = darkMode ? darkHex : lightHex
            var s = hex
            if s.hasPrefix("#") { s.removeFirst() }
            var v: UInt64 = 0
            Scanner(string: s).scanHexInt64(&v)
            return NSColor(
                red: CGFloat((v >> 16) & 0xFF) / 255,
                green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255,
                alpha: CGFloat(darkMode ? dark : light)
            )
        })
    }

    // MARK: - 中性色层级（背景 → 卡片 → 控件 → 分割线）

    static let bg = mag("#f4f4f6", "#1a1a1e")
    static let card = mag("#ffffff", "#232327")
    static let card2 = mag("#f9f9fb", "#1f1f23")
    static let pill = mag("#f1f1f4", "#2d2d33")
    static let pillHover = mag("#e9e9ee", "#36363d")
    static let line = mag("#e3e3e8", "#333339")
    static let line2 = mag("#ececf0", "#2c2c32")
    /// 弹层毛玻璃基底（94% 亮 / 96% 暗）
    static let popTint = magAlpha(0.94, 0.96, base: "#ffffff", darkHex: "#26262b")

    // MARK: - 文字 5 级灰阶

    static let fg = mag("#1c1c21", "#ededf1")
    static let fg2 = mag("#4b4b53", "#b9b9c1")
    static let muted = mag("#85858d", "#8b8b94")
    static let faint = mag("#b9b9c2", "#56565f")
    static let ctlFg = mag("#63636b", "#a1a1aa")

    // MARK: - 强调色（亮 #4f46e5 / 暗提亮 #a5b4fc，其上文字换深色）

    static let accent = mag("#4f46e5", "#a5b4fc")
    static let accentSoft = mag("#eeedfd", "#2b2c47")
    static let accentFg = mag("#ffffff", "#14142a")
    static let sel = mag("#ecebfb", "#33345a")

    // MARK: - 语义色（实体色 + soft 软底成对）

    static let green = mag("#189a58", "#6fd99b")
    static let greenSoft = mag("#e4f6ec", "#1e3a2b")
    static let red = mag("#d64545", "#f28b82")
    static let redSoft = mag("#fbe9e9", "#45272a")
    static let amber = mag("#b45309", "#f2b544")
    static let amberSoft = mag("#fbf0df", "#3f3220")

    // MARK: - 截图交互保留色（微信范式，不受主题影响）

    static let selectionBlue = Color(red: 15 / 255, green: 135 / 255, blue: 255 / 255) // #0f87ff
    static let wechatGreen = Color(red: 7 / 255, green: 193 / 255, blue: 96 / 255)     // #07c160

    // MARK: - 圆角阶梯（小控件 6 / 容器 10 / 面板 12 / 模态 14）

    static let radiusControl: CGFloat = 6
    static let radiusCard: CGFloat = 10
    static let cardRadius: CGFloat = 10
    static let popRadius: CGFloat = 12
    static let radiusModal: CGFloat = 14

    // MARK: - 兼容别名

    /// 卡片/行填充（选中态用 sel）
    static let cardFill = card
    static let cardFillHover = sel

    // MARK: - 字号刻度（10.5–13px 工具型刻度）

    static let fsBody: CGFloat = 13
    static let fsControl: CGFloat = 12.5
    static let fsSecondary: CGFloat = 12
    static let fsMicro: CGFloat = 11
    static let fsTiny: CGFloat = 10.5

    // MARK: - 时间与分组

    static func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// 列表时间：今天显示 HH:mm，非今天补日期（等宽数字由调用方加 monospacedDigit）
    static func listTime(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return timeString(date) }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }

    static func fullString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }

    static func groupLabel(for date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "今天" }
        if cal.isDateInYesterday(date) { return "昨天" }
        if let weekAgo = cal.date(byAdding: .day, value: -7, to: now),
           date > weekAgo { return "本周" }
        return "更早"
    }

    // MARK: - 来源应用显示名

    static func appName(_ item: ClipItem) -> String {
        if item.sourceApp == "screenshot" { return "截图" }
        if let name = item.sourceName, !name.isEmpty { return name }
        if let bundle = item.sourceApp {
            let short = bundle.split(separator: ".").last.map(String.init) ?? bundle
            return short.prefix(1).capitalized + short.dropFirst()
        }
        return "未知"
    }

    // MARK: - 类型图标

    static func kindSymbol(_ kind: ClipKind) -> String {
        switch kind {
        case .text: return "doc.text"
        case .image: return "photo"
        case .files: return "folder"
        case .screenshot: return "camera.viewfinder"
        }
    }

    /// 条目尺寸/字数描述
    static func sizeDescription(_ item: ClipItem) -> String {
        switch item.kind {
        case .image, .screenshot:
            if let w = item.width, let h = item.height { return "\(w)×\(h)" }
            return "图片"
        case .text:
            if let n = item.charCount { return "\(n) 字" }
            return "文本"
        case .files:
            guard let text = item.textContent else { return "文件" }
            let count = text.split(separator: "\n").count
            return count > 1 ? "\(count) 个文件" : "1 个文件"
        }
    }
}
