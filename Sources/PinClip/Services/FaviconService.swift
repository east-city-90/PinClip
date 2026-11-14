import AppKit

/// 来源图标服务：
/// 1) 来源 App → NSWorkspace 本地应用图标（零网络）
/// 2) 来源 URL → 站点 favicon（直接请求目标网站 /favicon.ico，不用第三方服务，遵守无遥测承诺），磁盘缓存
enum FaviconService {

    private static let faviconsDir = Paths.appSupport.appendingPathComponent("Favicons", isDirectory: true)

    /// 依据条目取图标：App 图标优先；无 App 信息但有 URL 时取 favicon
    /// - Parameters:
    ///   - item: 条目
    ///   - allowNetwork: 设置里的「在线获取网站图标」开关
    static func icon(for item: ClipItem, allowNetwork: Bool) async -> NSImage? {
        if let bundle = item.sourceApp, bundle != "screenshot",
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 32, height: 32)
            return icon
        }
        if let url = item.sourceURL, let host = URL(string: url)?.host {
            return await favicon(host: host, allowNetwork: allowNetwork)
        }
        return nil
    }

    /// favicon：磁盘缓存 → 网络拉取 → 失败返回 nil（UI 回退到字母徽标）
    static func favicon(host: String, allowNetwork: Bool) async -> NSImage? {
        let safeHost = host.replacingOccurrences(of: "[^a-zA-Z0-9.-]", with: "", options: .regularExpression)
        guard !safeHost.isEmpty else { return nil }

        try? FileManager.default.createDirectory(at: faviconsDir, withIntermediateDirectories: true)
        let cacheFile = faviconsDir.appendingPathComponent("\(safeHost).png")
        if let cached = NSImage(contentsOf: cacheFile) {
            return cached
        }
        guard allowNetwork else { return nil }

        guard let url = URL(string: "https://\(safeHost)/favicon.ico") else { return nil }
        let request = URLRequest(url: url, timeoutInterval: 3)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = NSImage(data: data)
        else { return nil }

        // 统一转 PNG 落盘缓存（无论源格式）
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: cacheFile, options: .atomic)
        }
        return image
    }

    /// 详情页展示用的 host 短名（meta 行追加显示）
    static func hostDisplay(_ sourceURL: String?) -> String? {
        guard let sourceURL, let url = URL(string: sourceURL), let host = url.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
