import AppKit

/// 剪贴板读取：三类内容识别（设计方案 §3.1 剪贴板层）
/// 分类优先级：文件 URL > 图片 > 文本。图片+短文本并存视为图片复制（浏览器右键复制图片会附带 HTML），
/// 图片+长文本并存视为文本复制（如 Excel 同时放图片与数据）。
enum ClipboardReader {

    enum Content {
        case text(String)
        case image(png: Data, width: Int, height: Int)
        case files([String])
        case none
    }

    static func readCurrent() -> Content {
        let pb = NSPasteboard.general

        // 1) 文件 URL
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return .files(urls.map { $0.path })
        }

        // 2) 图片（PNG 或 TIFF 原始数据，避免 NSImage 对文件路径的隐式解析）
        let pngData = pb.data(forType: .png)
        if pngData != nil || pb.data(forType: .tiff) != nil {
            if let (data, w, h) = imagePayload(png: pngData, tiff: pb.data(forType: .tiff)) {
                let text = pb.string(forType: .string) ?? ""
                let looksLikeImageCopy = text.isEmpty || text.count <= 256 || isHTML(text)
                if looksLikeImageCopy {
                    return .image(png: data, width: w, height: h)
                }
            }
        }

        // 3) 文本
        if let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .text(text)
        }

        // 图片但被上面判定为文本的分支漏掉时兜底（长文本+图片并存→文本已在上面返回；纯图片走到这里）
        if let (data, w, h) = imagePayload(png: pngData, tiff: pb.data(forType: .tiff)) {
            return .image(png: data, width: w, height: h)
        }
        return .none
    }

    /// F3 贴图：仅取剪贴板当前图片（无文本分支干扰）
    static func currentImagePNG() -> Data? {
        let pb = NSPasteboard.general
        if let (data, _, _) = imagePayload(png: pb.data(forType: .png), tiff: pb.data(forType: .tiff)) {
            return data
        }
        return nil
    }

    /// 来源 URL 提取（复制链接时浏览器会放 public.url；复制纯 URL 文本时从内容识别）。
    /// 仅接受 http/https；普通正文复制通常不携带来源，返回 nil 属正常。
    static func currentSourceURL() -> String? {
        let pb = NSPasteboard.general

        // 1) public.url（复制网页链接时存在；文件路径的 NSURL 已在 readCurrent 里按 files 处理）
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
           let url = urls.first(where: { $0.scheme == "http" || $0.scheme == "https" }) {
            return url.absoluteString
        }

        // 2) 文本内容本身是 URL（http(s) 开头、不含任何空白）
        if let text = pb.string(forType: .string) {
            let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
               line.lowercased().hasPrefix("http://") || line.lowercased().hasPrefix("https://"),
               let url = URL(string: line), url.host != nil {
                return url.absoluteString
            }
        }
        return nil
    }

    private static func isHTML(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower.contains("<html") || lower.contains("img src") || lower.contains("<img")
    }

    private static func imagePayload(png: Data?, tiff: Data?) -> (Data, Int, Int)? {
        if let png {
            if let size = ImageKit.pixelSize(of: png) {
                return (png, size.width, size.height)
            }
        }
        if let tiff, let rep = NSBitmapImageRep(data: tiff) {
            if let out = rep.representation(using: .png, properties: [:]) {
                return (out, rep.pixelsWide, rep.pixelsHigh)
            }
        }
        return nil
    }
}

/// 剪贴板写回（回填/截图复制/贴图复制）
enum ClipboardWriter {

    static func writeText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func writeImagePNG(_ png: Data) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
        // TIFF 兼容旧式 App
        if let rep = NSBitmapImageRep(data: png) ?? ImageKit.cgImage(from: png).map(NSBitmapImageRep.init(cgImage:)),
           let tiff = rep.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
    }

    static func writeFiles(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }

    /// 历史条目回填剪贴板
    static func writeItem(_ item: ClipItem) {
        switch item.kind {
        case .text:
            if let t = item.textContent { writeText(t) }
        case .image, .screenshot:
            if let path = item.mediaPath, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                writeImagePNG(data)
            }
        case .files:
            if let t = item.textContent {
                writeFiles(t.split(separator: "\n").map(String.init))
            }
        }
    }
}

/// 来源 App（changeCount 变化瞬间的前台应用）
extension AppSource {
    static func current() -> AppSource {
        if let app = NSWorkspace.shared.frontmostApplication {
            return AppSource(bundleID: app.bundleIdentifier, name: app.localizedName)
        }
        return AppSource(bundleID: nil, name: nil)
    }
}
