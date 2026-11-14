import Foundation
import SQLite3

/// SQLite3 C API 轻封装（线程安全由 FULLMUTEX + 调用方串行保证）
final class Database {
    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "pinclip.db")

    /// SQLITE_TRANSIENT：让 SQLite 自行复制绑定字符串
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        var h: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let opened = h else {
            if let h { sqlite3_close(h) }
            throw StoreError.openFailed(rc)
        }
        handle = opened
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA busy_timeout=2000;")
        try exec("""
        CREATE TABLE IF NOT EXISTS items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            kind TEXT NOT NULL,
            content_hash TEXT NOT NULL,
            text_content TEXT,
            media_path TEXT,
            thumb_path TEXT,
            source_app TEXT,
            source_name TEXT,
            width INTEGER,
            height INTEGER,
            pinned INTEGER DEFAULT 0,
            hit_count INTEGER DEFAULT 1,
            created_at REAL NOT NULL,
            sensitive INTEGER DEFAULT 0
        );
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_created ON items(created_at DESC);")
        try exec("CREATE INDEX IF NOT EXISTS idx_hash ON items(content_hash);")
        migrate()
    }

    /// 旧库平滑加列（CREATE TABLE IF NOT EXISTS 不会补列）
    private func migrate() {
        ensureColumn("items", "source_url", "TEXT")
    }

    private func ensureColumn(_ table: String, _ column: String, _ decl: String) {
        var exists = false
        try? query("PRAGMA table_info(\(table))") { r in
            if r.text(1) == column { exists = true }
        }
        if !exists {
            try? exec("ALTER TABLE \(table) ADD COLUMN \(column) \(decl);")
        }
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    enum StoreError: Error {
        case openFailed(Int32)
        case execFailed(Int32, String)
        case bindFailed(Int32)
        case stepFailed(Int32)
    }

    // MARK: 执行

    func exec(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errMsg)
        let message = errMsg.map { String(cString: $0) }
        if let errMsg { sqlite3_free(errMsg) }
        guard rc == SQLITE_OK else { throw StoreError.execFailed(rc, message ?? sql) }
    }

    /// 写入事务包装
    func transaction(_ body: () throws -> Void) throws {
        try queue.sync {
            try exec("BEGIN IMMEDIATE;")
            do {
                try body()
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    // MARK: 查询

    /// 通用查询；row 回调按列序读取
    func query(_ sql: String, binds: [SQLValue] = [], row: (RowReader) throws -> Void) throws {
        try queue.sync {
            var stmt = OpaquePointer?.none
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw StoreError.execFailed(sqlite3_errcode(handle), sql)
            }
            defer { sqlite3_finalize(stmt) }
            try bindValues(stmt, binds)
            while sqlite3_step(stmt) == SQLITE_ROW {
                try row(RowReader(stmt: stmt))
            }
        }
    }

    func run(_ sql: String, binds: [SQLValue]) throws {
        try queue.sync {
            var stmt = OpaquePointer?.none
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw StoreError.execFailed(sqlite3_errcode(handle), sql)
            }
            defer { sqlite3_finalize(stmt) }
            try bindValues(stmt, binds)
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw StoreError.stepFailed(rc) }
        }
    }

    func scalarInt(_ sql: String, binds: [SQLValue] = []) -> Int? {
        var result: Int?
        try? query(sql, binds: binds) { r in
            if result == nil { result = r.int(0) }
        }
        return result
    }

    private func bindValues(_ stmt: OpaquePointer, _ binds: [SQLValue]) throws {
        for (i, value) in binds.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch value {
            case .int(let v): rc = sqlite3_bind_int64(stmt, idx, Int64(v))
            case .double(let v): rc = sqlite3_bind_double(stmt, idx, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            case .null: rc = sqlite3_bind_null(stmt, idx)
            }
            guard rc == SQLITE_OK else { throw StoreError.bindFailed(rc) }
        }
    }
}

enum SQLValue {
    case int(Int)
    case double(Double)
    case text(String)
    case null
}

/// 单行列读取器
struct RowReader {
    let stmt: OpaquePointer

    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func text(_ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }
    func optionalInt(_ i: Int32) -> Int? {
        sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : int(i)
    }
    func optionalText(_ i: Int32) -> String? { text(i) }
}
