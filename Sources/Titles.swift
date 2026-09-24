import Foundation
import SQLite3

/// Claude Code's derived session names ("worcester-a6") say nothing about the
/// work. Conductor stores the chat title the user actually recognises, keyed by
/// the same session id, so prefer that when this session belongs to Conductor.
///
/// The database is opened read-only and every failure degrades to an empty map:
/// it belongs to another application and its schema is not a contract.
func conductorTitles() -> [String: String] {
    let path = NSHomeDirectory()
        + "/Library/Application Support/com.conductor.app/conductor.db"
    guard FileManager.default.fileExists(atPath: path) else { return [:] }

    var db: OpaquePointer?
    // Immutable would skip the WAL and miss recent titles; read-only does not.
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        sqlite3_close(db)
        return [:]
    }
    defer { sqlite3_close(db) }

    var stmt: OpaquePointer?
    let sql = """
    SELECT claude_session_id, title FROM sessions
    WHERE claude_session_id IS NOT NULL AND title IS NOT NULL AND title != ''
    """
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
    defer { sqlite3_finalize(stmt) }

    var out: [String: String] = [:]
    while sqlite3_step(stmt) == SQLITE_ROW {
        guard let sid = sqlite3_column_text(stmt, 0),
              let title = sqlite3_column_text(stmt, 1) else { continue }
        out[String(cString: sid)] = String(cString: title)
    }
    return out
}

/// Current branch of a working directory, used when there is no Conductor title.
func gitBranch(_ cwd: String) -> String? {
    guard !cwd.isEmpty else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    let branch = String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return branch.isEmpty || branch == "HEAD" ? nil : branch
}

func truncate(_ s: String, _ limit: Int) -> String {
    s.count <= limit ? s : String(s.prefix(limit - 1)) + "…"
}
