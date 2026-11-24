import AppKit
import CryptoKit

/// 图像编解码/缩放/马赛克工具（CoreGraphics + ImageIO，全部线程安全）
enum ImageKit {

    // MARK: 编解码

    static func pngData(_ cg: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])
    }

    static func cgImage(from data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap {
            CGImageSourceCreateImageAtIndex($0, 0, nil)
        }
    }

    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }

    /// 剪贴板位图规范化：png 有效直接用；否则 TIFF → PNG。
    /// 只做数据级判断（不解码像素），真正的解码/编码由调用方放在后台队列。
    static func canonicalImage(png: Data?, tiff: Data?) -> (data: Data, width: Int, height: Int)? {
        if let png, let size = pixelSize(of: png) { return (png, size.width, size.height) }
        if let tiff, let rep = NSBitmapImageRep(data: tiff),
           let out = rep.representation(using: .png, properties: [:]) {
            return (out, rep.pixelsWide, rep.pixelsHigh)
        }
        return nil
    }

    /// 取图像某像素的颜色（hex）。1×1 上下文绘制，代价极小，可实时调用（放大镜/贴图取色）。
    /// 坐标为图像像素（左上原点）。失败或越界返回 nil。
    static func sampleColor(of image: CGImage, atPixel p: CGPoint) -> String? {
        guard p.x >= 0, p.y >= 0, p.x < CGFloat(image.width), p.y < CGFloat(image.height),
              let ctx = CGContext(
                  data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        // 把图像画成"目标像素落在 (0,0)"：top-left 像素 (x,y) 映射到 ctx 点 (minX+x, maxY-y)
        let rect = CGRect(x: -p.x, y: p.y - CGFloat(image.height),
                          width: CGFloat(image.width), height: CGFloat(image.height))
        ctx.draw(image, in: rect)
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: 4)
        return String(format: "#%02X%02X%02X", px[0], px[1], px[2])
    }

    // MARK: 缩略图

    /// 缩略图 ≤maxDim；不透明图存 JPEG（更小），含透明存 PNG；返回 (路径, 宽, 高)
    static func thumbnail(png: Data, maxDim: CGFloat) -> (path: String, width: Int, height: Int)? {
        guard let cg = cgImage(from: png) else { return nil }
        guard let small = downscaled(cg, maxDim: maxDim) else { return nil }
        let hasAlpha = small.alphaInfo != .none && small.alphaInfo != .noneSkipFirst && small.alphaInfo != .noneSkipLast
        let ext = hasAlpha ? "png" : "jpg"
        let rep = NSBitmapImageRep(cgImage: small)
        guard let out = rep.representation(using: hasAlpha ? .png : .jpeg, properties: [.compressionFactor: 0.8]) else { return nil }
        return nil2(out, ext, small)
    }

    private static func nil2(_ data: Data, _ ext: String, _ cg: CGImage)
        -> (path: String, width: Int, height: Int)? {
        let hash = sha256Hex(data).prefix(16)
        let url = Paths.mediaURL(hash: "t\(hash)", ext: ext)
        do { try data.write(to: url, options: .atomic) } catch { return nil }
        return (url.path, cg.width, cg.height)
    }

    // MARK: 缩放（High Quality 上下采样）

    static func downscaled(_ cg: CGImage, maxDim: CGFloat) -> CGImage? {
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(maxDim / max(w, h), 1.0)
        if scale >= 1.0 { return cg }
        let nw = max(Int(w * scale), 1), nh = max(Int(h * scale), 1)
        return resized(cg, toWidth: nw, height: nh)
    }

    static func resized(_ cg: CGImage, toWidth w: Int, height h: Int) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// 马赛克：先缩到极小再最近邻放大，产出块状 CGImage（截图会话预计算一次）
    static func pixelated(_ cg: CGImage, block: CGFloat = 18) -> CGImage? {
        let smallW = max(Int(CGFloat(cg.width) / block), 1)
        let smallH = max(Int(CGFloat(cg.height) / block), 1)
        guard let small = resized(cg, toWidth: smallW, height: smallH) else { return nil }
        guard let ctx = CGContext(
            data: nil, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(small, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return ctx.makeImage()
    }

    // MARK: 水印

    /// 在截图角落叠加半透明水印文字（带轻微投影保证可读）
    static func watermarked(_ image: CGImage, text: String, corner: String,
                            opacity: Double, scale: CGFloat) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let font = NSFont.systemFont(ofSize: 14 * scale, weight: .medium)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 2 * scale
        shadow.shadowOffset = CGSize(width: 0, height: -1 * scale)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(opacity),
            .shadow: shadow,
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        let textSize = attr.size()
        let margin = 16 * scale

        let x: CGFloat
        let yFlipped: CGFloat
        switch corner {
        case "topLeft": x = margin; yFlipped = margin
        case "topRight": x = CGFloat(w) - margin - textSize.width; yFlipped = margin
        case "bottomLeft": x = margin; yFlipped = CGFloat(h) - margin - textSize.height
        default: x = CGFloat(w) - margin - textSize.width; yFlipped = CGFloat(h) - margin - textSize.height
        }

        // 用翻转的 NSGraphicsContext 让 NSAttributedString.draw 以左上原点绘制
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        attr.draw(at: NSPoint(x: x, y: yFlipped))
        NSGraphicsContext.restoreGraphicsState()

        return ctx.makeImage()
    }

    // MARK: 哈希

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: 截图装饰（CleanShot 式：渐变背景 + 圆角 + 投影）

    /// 截图外包一层装饰画布：柔和渐变背景、内容圆角卡片、下方投影
    static func decorated(_ image: CGImage, scale: CGFloat, dark: Bool) -> CGImage? {
        let pad = Int(36 * scale)
        let radius = 12 * scale
        let w = image.width + pad * 2
        let h = image.height + pad * 2
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // 背景：垂直渐变
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let top = dark ? CGColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1) : CGColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1)
        let bottom = dark ? CGColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1) : CGColor(red: 0.89, green: 0.89, blue: 0.92, alpha: 1)
        if let grad = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: CGFloat(h)), options: [])
        }

        let card = CGRect(x: pad, y: pad, width: image.width, height: image.height)
        let rounded = CGPath(roundedRect: card, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // 1) 带投影的底板（阴影画在未裁剪层，避免被裁掉）
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -6 * scale),
            blur: 16 * scale,
            color: CGColor(red: 0, green: 0, blue: 0, alpha: dark ? 0.55 : 0.28)
        )
        ctx.addPath(rounded)
        ctx.setFillColor(dark ? CGColor(red: 0.16, green: 0.16, blue: 0.18, alpha: 1) : CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        // 2) 圆角裁剪后贴入截图
        ctx.saveGState()
        ctx.addPath(rounded)
        ctx.clip()
        ctx.draw(image, in: card)
        ctx.restoreGState()

        return ctx.makeImage()
    }
}
