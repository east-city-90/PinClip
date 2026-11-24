import AppKit
import ImageIO

/// 图片解码缓存：列表缩略图 + 详情大图统一走 ImageIO 降采样（后台解码，杜绝主线程卡顿）
enum ImageCache {

    private static let thumbs: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 400
        c.totalCostLimit = 48 * 1024 * 1024
        return c
    }()
    private static let details: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 40
        c.totalCostLimit = 128 * 1024 * 1024
        return c
    }()
    private static let queue = DispatchQueue(label: "pinclip.imagecache", qos: .userInitiated)

    static func cachedThumb(_ path: String) -> NSImage? {
        thumbs.object(forKey: path as NSString)
    }

    static func cachedDetail(_ path: String) -> NSImage? {
        details.object(forKey: path as NSString)
    }

    /// 列表小缩略图（64px 足够 24×24 显示）
    static func loadThumb(path: String) async -> NSImage? {
        if let cached = thumbs.object(forKey: path as NSString) { return cached }
        return await withCheckedContinuation { cont in
            queue.async {
                let img = downsampled(path: path, maxPixel: 64)
                if let img { thumbs.setObject(img, forKey: path as NSString) }
                DispatchQueue.main.async { cont.resume(returning: img) }
            }
        }
    }

    /// 详情大图（按显示尺寸降采样，4000px 原图解码从数百 ms 降到几十 ms）
    static func loadDetail(path: String, maxPixel: Int = 1600) async -> NSImage? {
        if let cached = details.object(forKey: path as NSString) { return cached }
        return await withCheckedContinuation { cont in
            queue.async {
                let img = downsampled(path: path, maxPixel: maxPixel)
                if let img { details.setObject(img, forKey: path as NSString) }
                DispatchQueue.main.async { cont.resume(returning: img) }
            }
        }
    }

    /// ImageIO 缩略图解码（kCGImageSourceThumbnailMaxPixelSize 直接产出目标尺寸）
    private static func downsampled(path: String, maxPixel: Int) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, srcOpts) else { return nil }
        let thumbOpts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
