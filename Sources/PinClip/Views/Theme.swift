import SwiftUI

/// magpie 设计令牌的原生映射：靛蓝主色 + 毛玻璃材质 + 13px 密集刻度
enum Theme {
    /// 主色：跟随系统强调色（系统设置 → 外观 → 强调色），动态响应用户切换
    static var accent: Color { Color(nsColor: .controlAccentColor) }

    // 截图交互色（微信范式）
    static let selectionBlue = Color(red: 15 / 255, green: 135 / 255, blue: 255 / 255) // #0f87ff
    static let wechatGreen = Color(red: 7 / 255, green: 193 / 255, blue: 96 / 255)     // #07c160
    static let cardRadius: CGFloat = 10
    static let popRadius: CGFloat = 12

    /// 卡片材质（毛玻璃感由窗口 material 提供，卡片用次级底色）
    static let cardFill = Color.primary.opacity(0.055)
    static let cardFillHover = Color.primary.opacity(0.10)

    // MARK: 时间与分组

    static func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
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

    // MARK: 来源应用显示名

    static func appName(_ item: ClipItem) -> String {
        if item.sourceApp == "screenshot" { return "截图" }
        if let name = item.sourceName, !name.isEmpty { return name }
        if let bundle = item.sourceApp {
            let short = bundle.split(separator: ".").last.map(String.init) ?? bundle
            return short.prefix(1).capitalized + short.dropFirst()
        }
        return "未知"
    }

    // MARK: 类型图标

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
