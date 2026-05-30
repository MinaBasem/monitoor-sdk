import Foundation
import SQLite3

enum BufferError: Error {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
}

/// Thread-safe SQLite WAL queue. All reads and writes are serialized on a dedicated queue.
final class LocalBuffer {

    // Allow injection of an in-memory path for tests.
    static let defaultPath: String = {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return library.appendingPathComponent("monitoor_buffer.db").path
    }()

    private var db: OpaquePointer?
    private let queue: DispatchQueue
    private let dbPath: String

    init(path: String = LocalBuffer.defaultPath) throws {
        self.dbPath = path
        self.queue = DispatchQueue(label: "io.monitoor.buffer", qos: .utility)
        try queue.sync { try self.open() }
    }

    deinit {
        if let db = db { sqlite3_close(db) }
    }

    // MARK: - Public API

    func enqueue(payload: Data, type: BufferRowType) throws {
        guard let json = String(data: payload, encoding: .utf8) else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try queue.sync {
            try exec(
                "INSERT INTO buffer (payload, type, created_at) VALUES (?, ?, ?);",
                bindings: [.text(json), .text(type.rawValue), .int64(now)]
            )
        }
    }

    func dequeue(limit: Int) throws -> [BufferedEvent] {
        try queue.sync {
            var rows: [BufferedEvent] = []
            let stmt = try prepare(
                "SELECT id, payload, type FROM buffer WHERE status = 'pending' ORDER BY id ASC LIMIT ?;"
            )
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let rowId  = sqlite3_column_int64(stmt, 0)
                let payloadCStr = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let typeCStr    = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "event"
                guard let data = payloadCStr.data(using: .utf8) else { continue }
                let rowType = BufferRowType(rawValue: typeCStr) ?? .event
                rows.append(BufferedEvent(rowId: rowId, payload: data, type: rowType))
            }
            return rows
        }
    }

    func markSent(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try queue.sync {
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            try exec(
                "DELETE FROM buffer WHERE id IN (\(placeholders));",
                bindings: ids.map { .int64($0) }
            )
        }
    }

    func markFailed(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try queue.sync {
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            try exec(
                "UPDATE buffer SET status = 'failed', attempts = attempts + 1 WHERE id IN (\(placeholders));",
                bindings: ids.map { .int64($0) }
            )
        }
    }

    func incrementAttempts(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try queue.sync {
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            try exec(
                "UPDATE buffer SET attempts = attempts + 1 WHERE id IN (\(placeholders));",
                bindings: ids.map { .int64($0) }
            )
        }
    }

    func pruneExpired(maxAge: TimeInterval) throws {
        let cutoff = Int64((Date().timeIntervalSince1970 - maxAge) * 1000)
        try queue.sync {
            try exec(
                "DELETE FROM buffer WHERE created_at < ?;",
                bindings: [.int64(cutoff)]
            )
        }
    }

    func pendingCount() throws -> Int {
        try queue.sync {
            let stmt = try prepare("SELECT COUNT(*) FROM buffer WHERE status = 'pending';")
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    // MARK: - Private helpers

    private func open() throws {
        // Exclude from iCloud backup.
        var url = URL(fileURLWithPath: dbPath)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? url.setResourceValues(resourceValues)

        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw BufferError.openFailed(errorMessage)
        }
        try rawExec(BufferSchema.enableWAL)
        try rawExec(BufferSchema.syncNormal)
        try rawExec(BufferSchema.foreignKeys)
        try rawExec(BufferSchema.createTable)
        try rawExec(BufferSchema.createStatusIndex)
    }

    private func rawExec(_ sql: String) throws {
        var errmsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errmsg) == SQLITE_OK else {
            let msg = errmsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errmsg)
            throw BufferError.stepFailed(msg)
        }
    }

    private enum Binding {
        case text(String)
        case int64(Int64)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw BufferError.prepareFailed(errorMessage)
        }
        return s
    }

    private func exec(_ sql: String, bindings: [Binding]) throws {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        for (i, binding) in bindings.enumerated() {
            let col = Int32(i + 1)
            switch binding {
            case .text(let s):  sqlite3_bind_text(stmt, col, s, -1, SQLITE_TRANSIENT)
            case .int64(let v): sqlite3_bind_int64(stmt, col, v)
            }
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw BufferError.stepFailed(errorMessage)
        }
    }

    private var errorMessage: String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "db not open"
    }
}

// SQLite transient destructor constant for text bindings.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
