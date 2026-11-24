import Foundation

/// 图片文件识别（访达复制的单个图片文件按图片条目对待）
enum ImageFileTypes {
    static let extensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "jfif", "jp2",
    ]

    static func isImage(path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return extensions.contains(ext)
    }
}
