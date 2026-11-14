import Foundation

/// 隐私过滤（设计方案 §3.1 隐私层）：
/// 1. 密码管理器来源排除（bundle id 名单）
/// 2. 敏感正则：疑似密码/卡号/私钥不入库
enum PrivacyFilter {

    /// 返回 (是否记录, 拒绝原因)
    static func shouldRecord(settings: AppSettings, kind: ClipKind, text: String?, source: AppSource) -> (Bool, String?) {
        if settings.paused { return (false, "paused") }

        // 来源排除
        if let bundle = source.bundleID, settings.excludedBundles.contains(bundle) {
            return (false, "excluded-app")
        }

        // 敏感内容检测（文本与文件路径名单均检查）
        if settings.sensitiveFilter, let t = text, isSensitive(t) {
            return (false, "sensitive")
        }
        return (true, nil)
    }

    static func isSensitive(_ text: String) -> Bool {
        // PEM 私钥
        if text.range(of: "BEGIN [A-Z ]*PRIVATE KEY", options: .regularExpression) != nil { return true }
        // 赋值形式的密钥类字段：password=xxx / token: xxx
        if text.range(of: #"(?i)\b(password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|session[_-]?id)\b\s*[:=]\s*\S{4,}"#, options: .regularExpression) != nil {
            return true
        }
        // 银行卡号样式（13–19 位，可含空格/连字符）+ Luhn 校验通过
        if let range = text.range(of: #"\b(?:\d[ -]?){12,18}\d\b"#, options: .regularExpression) {
            let digits = text[range].filter { $0.isNumber }
            if digits.count >= 13, digits.count <= 19, luhn(String(digits)) { return true }
        }
        return false
    }

    /// Luhn 校验
    static func luhn(_ s: String) -> Bool {
        var sum = 0
        var double = false
        for ch in s.reversed() {
            guard let d = ch.wholeNumberValue else { return false }
            if double {
                let dd = d * 2
                sum += dd > 9 ? dd - 9 : dd
            } else {
                sum += d
            }
            double.toggle()
        }
        return sum % 10 == 0
    }
}
