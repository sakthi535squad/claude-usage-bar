import Foundation
import SQLite3

/// A desktop app that runs Claude Code sessions and keeps its own chat titles.
enum ChatApp: String {
    case conductor = "Conductor"
    case t3 = "T3 Code"

    var bundleId: String {
        switch self {
        case .conductor: return "com.conductor.app"
        case .t3: return "com.t3tools.t3code"
        }
    }
}

/// Claude Code's derived session names ("worcester-a6") say nothing about the
/// work. Conductor and T3 Code store the chat title the user actually
/// recognises, keyed by the same session id, so prefer that when there is one.
func chatTitles() -> [String: (title: String, app: ChatApp)] {
    var out: [String: (title: String, app: ChatApp)] = [:]
    for (sid, title) in t3Titles() { out[sid] = (title, .t3) }
    for (sid, title) in conductorTitles() { out[sid] = (title, .conductor) }
    return out
}

func conductorTitles(path: String = NSHomeDirectory()
                         + "/Library/Application Support/com.conductor.app/conductor.db") -> [String: String] {
    sqliteTitles(path: path, sql: """
    SELECT claude_session_id, title FROM sessions
    WHERE claude_session_id IS NOT NULL AND title IS NOT NULL AND title != ''
    """)
}

/// T3 Code keys threads by its own id; the Claude session a thread currently
/// resumes is in its provider runtime's resume cursor.
func t3Titles(path: String = NSHomeDirectory() + "/.t3/userdata/state.sqlite") -> [String: String] {
    sqliteTitles(path: path, sql: """
    SELECT json_extract(r.resume_cursor_json, '$.resume'), t.title
    FROM provider_session_runtime r JOIN projection_threads t USING (thread_id)
    WHERE r.provider_name = 'claudeAgent' AND t.deleted_at IS NULL
      AND json_extract(r.resume_cursor_json, '$.resume') IS NOT NULL AND t.title != ''
    """)
}

/// Session id to title from another app's database, opened read-only. Every
/// failure degrades to an empty map: the database belongs to another
/// application and its schema is not a contract.
private func sqliteTitles(path: String, sql: String) -> [String: String] {
    guard FileManager.default.fileExists(atPath: path) else { return [:] }

    var db: OpaquePointer?
    // Immutable would skip the WAL and miss recent titles; read-only does not.
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        sqlite3_close(db)
        return [:]
    }
    defer { sqlite3_close(db) }

    var stmt: OpaquePointer?
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

/// Current branch of a working directory, used when there is no chat title.
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
