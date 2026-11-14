import Foundation
import Observation

/// 历史存储：SQLite 元数据 + media 目录图片文件 + SHA256 去重 + 保留策略（设计方案 §5.3/5.4）
@MainActor
@Observable
final class HistoryStore {
    /// 任意数据变化自增，SwiftUI 面板据此刷新
    public private(set) var revision = 0

    private let db: Database
    private let ioQueue = DispatchQueue(label: "pinclip.store.io", qos: .userInitiated)
    private var settingsProvider: () -> AppSettings
    /// 清理孤儿媒体文件用：DB 引用集合与文件系统集合都需主线程读取，ioQueue 执行
    private var retentionTimer: Timer?

    init(settingsProvider: @escaping () -> AppSettings) {
        self.settingsProvider = settingsProvider
        do {
            db = try Database(url: Paths.dbURL)
        } catch {
            fatalError("PinClip: 历史库打开失败 \(error)")
        }
    }

    // MARK: - 写入（剪贴板监听/截图流程调用）

    static let columns = "id, kind, text_content, media_path, thumb_path, source_app, source_name, width, height, pinned, hit_count, created_at, source_url"

    /// 文本入库；命中去重则旧条目前移 + hit_count+1。返回是否写入。
    @discardableResult
    func record(text: String, source: AppSource, sourceURL: String? = nil) -> Bool {
        let hash = ImageKit.sha256Hex(Data(text.utf8))
        if bumpIfExists(hash: hash) { return true }
        return insertRecord(
            sql: """
            INSERT INTO items (kind, content_hash, text_content, source_app, source_name, source_url, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            """,
            binds: [.text(ClipKind.text.rawValue), .text(hash), .text(text),
                    .text(source.bundleID ?? ""), .text(source.name ?? ""),
                    sourceURL.map { SQLValue.text($0) } ?? .null,
                    .double(Date().timeIntervalSince1970)]
        )
    }

    /// 图片入库（截图 kind 用 .screenshot）。重活（写原图+缩略图）在 ioQueue。
    func recordImage(pngData: Data, source: AppSource, kind: ClipKind = .image, sourceURL: String? = nil) {
        guard kind == .image || kind == .screenshot else { return }
        ioQueue.async { [weak self] in
            let hash = ImageKit.sha256Hex(pngData)
            let size = ImageKit.pixelSize(of: pngData) ?? (0, 0)
            let original = Paths.mediaURL(hash: hash, ext: "png")
            do { try pngData.write(to: original, options: .atomic) } catch {
                NSLog("PinClip: 图片写入失败 \(error)")
                return
            }
            let thumb = ImageKit.thumbnail(png: pngData, maxDim: 320)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.bumpIfExists(hash: hash) { return }
                self.insertRecord(
                    sql: """
                    INSERT INTO items (kind, content_hash, text_content, media_path, thumb_path, source_app, source_name, source_url, width, height, created_at)
                    VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)
                    """,
                    binds: [
                        .text(kind.rawValue), .text(hash), .null,
                        .text(original.path),
                        thumb.map { SQLValue.text($0.path) } ?? .null,
                        .text(source.bundleID ?? ""), .text(source.name ?? ""),
                        sourceURL.map { SQLValue.text($0) } ?? .null,
                        .int(size.width), .int(size.height),
                        .double(Date().timeIntervalSince1970),
                    ]
                )
            }
        }
    }

    /// 文件路径列表入库（files），text_content 存换行分隔路径
    @discardableResult
    func recordFiles(paths: [String], source: AppSource, sourceURL: String? = nil) -> Bool {
        guard !paths.isEmpty else { return false }
        let joined = paths.joined(separator: "\n")
        let hash = ImageKit.sha256Hex(Data(joined.utf8))
        if bumpIfExists(hash: hash) { return true }
        return insertRecord(
            sql: """
            INSERT INTO items (kind, content_hash, text_content, source_app, source_name, source_url, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            """,
            binds: [.text(ClipKind.files.rawValue), .text(hash), .text(joined),
                    .text(source.bundleID ?? ""), .text(source.name ?? ""),
                    sourceURL.map { SQLValue.text($0) } ?? .null,
                    .double(Date().timeIntervalSince1970)]
        )
    }

    // MARK: - 读取（面板）

    func page(query: String, kind: HistoryFilter, limit: Int = 200) -> HistoryPage {
        var conditions: [String] = []
        var binds: [SQLValue] = []
        if kind != .all {
            let placeholders = kind.sqlKinds.map { _ in "?" }.joined(separator: ",")
            conditions.append("kind IN (\(placeholders))")
            binds.append(contentsOf: kind.sqlKinds.map { SQLValue.text($0) })
        }
        if !query.isEmpty {
            let escaped = query
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            conditions.append("text_content LIKE ? ESCAPE '\\'")
            binds.append(.text("%\(escaped)%"))
        }
        func selectSQL(pinnedFlag: Int, withLimit: Bool) -> String {
            var all = conditions
            all.append("pinned=\(pinnedFlag)")
            var sql = "SELECT \(Self.columns) FROM items WHERE \(all.joined(separator: " AND ")) ORDER BY created_at DESC"
            if withLimit { sql += " LIMIT ?" }
            return sql
        }

        var pinned: [ClipItem] = []
        var items: [ClipItem] = []
        do {
            try db.query(selectSQL(pinnedFlag: 1, withLimit: false), binds: binds) { r in
                pinned.append(Self.item(from: r))
            }
            var itemBinds = binds
            itemBinds.append(.int(limit))
            try db.query(selectSQL(pinnedFlag: 0, withLimit: true), binds: itemBinds) { r in
                items.append(Self.item(from: r))
            }
        } catch {
            NSLog("PinClip: 查询失败 \(error)")
        }
        return HistoryPage(pinned: pinned, items: items)
    }

    private static func item(from r: RowReader) -> ClipItem {
        ClipItem(
            id: Int64(r.int(0)),
            kind: ClipKind(rawValue: r.text(1) ?? "text") ?? .text,
            textContent: r.optionalText(2),
            mediaPath: r.optionalText(3),
            thumbPath: r.optionalText(4),
            sourceApp: r.optionalText(5),
            sourceName: r.optionalText(6),
            sourceURL: r.optionalText(12),
            width: r.optionalInt(7),
            height: r.optionalInt(8),
            pinned: r.int(9) == 1,
            hitCount: r.int(10),
            createdAt: Date(timeIntervalSince1970: r.double(11)),
            charCount: r.optionalText(2)?.count
        )
    }

    // MARK: - 面板操作

    func togglePin(id: Int64) -> Bool {
        let current = latestPinnedState(id: id)
        try? db.run("UPDATE items SET pinned=?1 WHERE id=?2", binds: [.int(current ? 0 : 1), .int(Int(id))])
        changed()
        return !current
    }

    func delete(id: Int64) {
        // 先取出媒体文件路径再删行删文件
        var paths: [String] = []
        try? db.query("SELECT media_path, thumb_path FROM items WHERE id=?1", binds: [.int(Int(id))]) { r in
            if let p = r.optionalText(0) { paths.append(p) }
            if let p = r.optionalText(1) { paths.append(p) }
        }
        try? db.run("DELETE FROM items WHERE id=?1", binds: [.int(Int(id))])
        for p in paths { try? FileManager.default.removeItem(atPath: p) }
        changed()
    }

    func clearAll(imagesOnly: Bool) {
        var paths: [String] = []
        try? db.query("SELECT media_path, thumb_path FROM items") { r in
            if let p = r.optionalText(0) { paths.append(p) }
            if let p = r.optionalText(1) { paths.append(p) }
        }
        if imagesOnly {
            try? db.run("DELETE FROM items WHERE kind IN (?1, ?2)", binds: [.text(ClipKind.image.rawValue), .text(ClipKind.screenshot.rawValue)])
        } else {
            try? db.run("DELETE FROM items", binds: [])
        }
        sweepOrphanMedia(referenced: []) // imagesOnly 时文本项媒体本就为空；全清则目录可整体清空
        if imagesOnly {
            for p in paths { try? FileManager.default.removeItem(atPath: p) }
        }
        changed()
    }

    /// 条目被使用（回填/贴图）：移动到顶部 + hit_count+1
    func bump(id: Int64) {
        try? db.run("UPDATE items SET created_at=?1, hit_count=hit_count+1 WHERE id=?2", binds: [
            .double(Date().timeIntervalSince1970), .int(Int(id)),
        ])
        changed()
    }

    func item(id: Int64) -> ClipItem? {
        var result: ClipItem?
        try? db.query("SELECT \(Self.columns) FROM items WHERE id=?1", binds: [.int(Int(id))]) { r in
            result = Self.item(from: r)
        }
        return result
    }

    func latestImageItem() -> ClipItem? {
        var result: ClipItem?
        try? db.query("SELECT \(Self.columns) FROM items WHERE kind IN (?1,?2) ORDER BY created_at DESC LIMIT 1", binds: [.text(ClipKind.image.rawValue), .text(ClipKind.screenshot.rawValue)]) { r in
            result = Self.item(from: r)
        }
        return result
    }

    // MARK: - 保留策略

    /// 启动后与每日执行：文本 500 条上限 / 图片 30 天 / 置顶永久 + 孤儿媒体清理
    func startRetentionLoop(settingsProvider: @escaping () -> AppSettings) {
        runRetention()
        retentionTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.runRetention() }
        }
    }

    func runRetention() {
        let settings = settingsProvider()
        ioQueue.async { [weak self] in
            guard let self else { return }
            // 文本/文件条数上限（置顶除外）
            let surplus = self.db.scalarInt("""
                SELECT COUNT(*) FROM items
                WHERE pinned=0 AND kind IN (?1, ?2) AND id NOT IN (
                    SELECT id FROM items WHERE pinned=0 AND kind IN (?1, ?2) ORDER BY created_at DESC LIMIT ?3
                )
                """, binds: [.text(ClipKind.text.rawValue), .text(ClipKind.files.rawValue), .int(settings.textLimit)]) ?? 0
            if surplus > 0 {
                try? self.db.run("""
                    DELETE FROM items WHERE pinned=0 AND kind IN (?1, ?2) AND id NOT IN (
                        SELECT id FROM items WHERE pinned=0 AND kind IN (?1, ?2) ORDER BY created_at DESC LIMIT ?3
                    )
                    """, binds: [.text(ClipKind.text.rawValue), .text(ClipKind.files.rawValue), .int(settings.textLimit)])
            }
            // 图片超期
            let cutoff = Date().addingTimeInterval(-Double(settings.imageDays) * 86400).timeIntervalSince1970
            var expiredPaths: [String] = []
            try? self.db.query("SELECT media_path, thumb_path FROM items WHERE pinned=0 AND kind IN (?1,?2) AND created_at < ?3", binds: [.text(ClipKind.image.rawValue), .text(ClipKind.screenshot.rawValue), .double(cutoff)]) { r in
                if let p = r.optionalText(0) { expiredPaths.append(p) }
                if let p = r.optionalText(1) { expiredPaths.append(p) }
            }
            try? self.db.run("DELETE FROM items WHERE pinned=0 AND kind IN (?1,?2) AND created_at < ?3", binds: [.text(ClipKind.image.rawValue), .text(ClipKind.screenshot.rawValue), .double(cutoff)])

            // 孤儿媒体清理：收集 DB 引用，比对文件系统
            var referenced = Set<String>()
            try? self.db.query("SELECT media_path, thumb_path FROM items") { r in
                if let p = r.optionalText(0) { referenced.insert(p) }
                if let p = r.optionalText(1) { referenced.insert(p) }
            }
            let fm = FileManager.default
            if let dirs = try? fm.contentsOfDirectory(at: Paths.mediaDir, includingPropertiesForKeys: nil) {
                for dir in dirs {
                    let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                    for f in files where !referenced.contains(f.path) {
                        try? fm.removeItem(at: f)
                    }
                    if (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.isEmpty == true {
                        try? fm.removeItem(at: dir)
                    }
                }
            }
            for p in expiredPaths { try? fm.removeItem(atPath: p) }

            DispatchQueue.main.async { [weak self] in
                if surplus > 0 || !expiredPaths.isEmpty { self?.changed() }
            }
        }
    }

    // MARK: - 私有

    private func insertRecord(sql: String, binds: [SQLValue]) -> Bool {
        do {
            try db.run(sql, binds: binds)
            changed()
            return true
        } catch {
            NSLog("PinClip: 写入失败 \(error)")
            return false
        }
    }

    private func bumpIfExists(hash: String) -> Bool {
        let existing = db.scalarInt("SELECT id FROM items WHERE content_hash=?1", binds: [.text(hash)])
        guard let id = existing else { return false }
        try? db.run("UPDATE items SET created_at=?1, hit_count=hit_count+1 WHERE id=?2", binds: [
            .double(Date().timeIntervalSince1970), .int(id),
        ])
        changed()
        return true
    }

    private func latestPinnedState(id: Int64) -> Bool {
        var pinned = false
        try? db.query("SELECT pinned FROM items WHERE id=?1", binds: [.int(Int(id))]) { r in
            pinned = r.int(0) == 1
        }
        return pinned
    }

    /// 清空历史时整体重建 media 目录（文本/文件条目无媒体文件）
    private func sweepOrphanMedia(referenced: Set<String>) {
        let fm = FileManager.default
        _ = referenced
        try? fm.removeItem(at: Paths.mediaDir)
        try? fm.createDirectory(at: Paths.mediaDir, withIntermediateDirectories: true)
    }

    private func changed() {
        revision += 1
        NotificationCenter.default.post(name: .pinclipHistoryChanged, object: nil)
    }
}
