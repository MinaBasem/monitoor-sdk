import Foundation

enum BufferSchema {
    static let createTable = """
        CREATE TABLE IF NOT EXISTS buffer (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            payload     TEXT    NOT NULL,
            type        TEXT    NOT NULL DEFAULT 'event',
            created_at  INTEGER NOT NULL,
            attempts    INTEGER NOT NULL DEFAULT 0,
            status      TEXT    NOT NULL DEFAULT 'pending'
        );
        """

    static let createStatusIndex = """
        CREATE INDEX IF NOT EXISTS idx_buffer_status
        ON buffer (status, created_at ASC);
        """

    static let enableWAL    = "PRAGMA journal_mode=WAL;"
    static let foreignKeys  = "PRAGMA foreign_keys=ON;"
    static let syncNormal   = "PRAGMA synchronous=NORMAL;"
}
