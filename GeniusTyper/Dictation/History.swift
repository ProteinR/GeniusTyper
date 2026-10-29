import Foundation
import SQLite3

/// One dictation in the history (text only, no audio).
struct HistoryEntry: Identifiable, Equatable {
    let id: Int64
    let date: Date
    let text: String
    let words: Int
    let duration: TimeInterval
    let appName: String
    let model: String
}

/// Totals for the statistics page.
struct Stats: Equatable {
    var words = 0
    var count = 0
    /// Seconds of speech.
    var duration: TimeInterval = 0
    var daysActive = 0
    /// Words per day (local dates "yyyy-MM-dd"), oldest first.
    var perDay: [(day: String, words: Int)] = []
    var byApp: [(name: String, words: Int)] = []
    var byModel: [(name: String, words: Int)] = []

    /// Typing speed the time saved is counted against (TypeWhisper's figure gives the same).
    static let typingWPM = 45.0

    var wordsPerMinute: Int { duration > 0 ? Int((Double(words) / (duration / 60)).rounded()) : 0 }
    var timeSaved: TimeInterval { max(0, Double(words) / Self.typingWPM * 60 - duration) }

    static func == (a: Stats, b: Stats) -> Bool {
        a.words == b.words && a.count == b.count && a.duration == b.duration && a.daysActive == b.daysActive
            && a.perDay.map(\.words) == b.perDay.map(\.words) && a.byApp.map(\.name) == b.byApp.map(\.name)
    }
}

enum Words {
    /// Words with a letter or digit ("—" and "-" alone are not words).
    static func count(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains { $0.isLetter || $0.isNumber } }.count
    }
}

/// The history in SQLite (`~/Library/Application Support/GeniusTyper/dictation/history.sqlite`). Nothing is kept
/// in memory: the database is opened for each operation, pages of the list and the statistics'
/// totals are computed by SQLite.
final class History {
    static let shared = History(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("GeniusTyper/dictation/history.sqlite"))

    let url: URL

    init(url: URL) {
        self.url = url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        withDB { db in
            exec(db, """
                CREATE TABLE IF NOT EXISTS dictations (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    date REAL NOT NULL,
                    text TEXT NOT NULL,
                    words INTEGER NOT NULL,
                    duration REAL NOT NULL,
                    app_bundle TEXT NOT NULL DEFAULT '',
                    app_name TEXT NOT NULL DEFAULT '',
                    model TEXT NOT NULL DEFAULT ''
                );
                CREATE INDEX IF NOT EXISTS dictations_date ON dictations(date);
                """)
        }
    }

    func add(text: String, duration: TimeInterval, appBundle: String, appName: String, model: String, date: Date = Date()) {
        withDB { db in
            let statement = prepare(db, "INSERT INTO dictations (date, text, words, duration, app_bundle, app_name, model) VALUES (?, ?, ?, ?, ?, ?, ?)")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            bind(statement, 2, text)
            sqlite3_bind_int64(statement, 3, Int64(Words.count(text)))
            sqlite3_bind_double(statement, 4, duration)
            bind(statement, 5, appBundle)
            bind(statement, 6, appName)
            bind(statement, 7, model)
            if sqlite3_step(statement) != SQLITE_DONE { Log.error("History insert failed: \(String(cString: sqlite3_errmsg(db)))", "history") }
        }
    }

    /// Newest first; `search` matches the text case-insensitively, Cyrillic included (`lower_ru`).
    func page(search: String = "", offset: Int, limit: Int) -> [HistoryEntry] {
        var result: [HistoryEntry] = []
        withDB { db in
            let filter = search.isEmpty ? "" : "WHERE instr(lower_ru(text), ?) > 0"
            let statement = prepare(db, "SELECT id, date, text, words, duration, app_name, model FROM dictations \(filter) ORDER BY date DESC LIMIT ? OFFSET ?")
            defer { sqlite3_finalize(statement) }
            var index: Int32 = 1
            if !search.isEmpty { bind(statement, index, search.lowercased()); index += 1 }
            sqlite3_bind_int(statement, index, Int32(limit))
            sqlite3_bind_int(statement, index + 1, Int32(offset))
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(HistoryEntry(id: sqlite3_column_int64(statement, 0),
                                        date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                                        text: string(statement, 2), words: Int(sqlite3_column_int64(statement, 3)),
                                        duration: sqlite3_column_double(statement, 4), appName: string(statement, 5),
                                        model: string(statement, 6)))
            }
        }
        return result
    }

    /// How many dictations there are.
    func count() -> Int {
        var result = 0
        withDB { db in
            let statement = prepare(db, "SELECT COUNT(*) FROM dictations")
            defer { sqlite3_finalize(statement) }
            if sqlite3_step(statement) == SQLITE_ROW { result = Int(sqlite3_column_int64(statement, 0)) }
        }
        return result
    }

    /// What the history takes on disk (one SQLite file).
    var bytes: Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// Deletes the dictations older than `days` days (0 = keeps all), then gives the space back.
    func prune(keepDays days: Int, now: Date = Date()) {
        guard days > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        withDB { db in
            let statement = prepare(db, "DELETE FROM dictations WHERE date < ?")
            sqlite3_bind_double(statement, 1, cutoff)
            sqlite3_step(statement)
            sqlite3_finalize(statement)
            if sqlite3_changes(db) > 0 { exec(db, "VACUUM") }
        }
    }

    func delete(id: Int64) {
        withDB { db in
            let statement = prepare(db, "DELETE FROM dictations WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, id)
            sqlite3_step(statement)
        }
    }

    /// Totals since `since` (nil = all time).
    func stats(since: Date?, now: Date = Date()) -> Stats {
        var stats = Stats()
        withDB { db in
            let start = since?.timeIntervalSince1970 ?? 0
            let totals = prepare(db, "SELECT COALESCE(SUM(words), 0), COUNT(*), COALESCE(SUM(duration), 0), COUNT(DISTINCT date(date, 'unixepoch', 'localtime')) FROM dictations WHERE date >= ?")
            sqlite3_bind_double(totals, 1, start)
            if sqlite3_step(totals) == SQLITE_ROW {
                stats.words = Int(sqlite3_column_int64(totals, 0))
                stats.count = Int(sqlite3_column_int64(totals, 1))
                stats.duration = sqlite3_column_double(totals, 2)
                stats.daysActive = Int(sqlite3_column_int64(totals, 3))
            }
            sqlite3_finalize(totals)

            func grouped(_ column: String) -> [(String, Int)] {
                let statement = prepare(db, "SELECT \(column), SUM(words) AS w FROM dictations WHERE date >= ? GROUP BY 1 ORDER BY w DESC")
                defer { sqlite3_finalize(statement) }
                sqlite3_bind_double(statement, 1, start)
                var rows: [(String, Int)] = []
                while sqlite3_step(statement) == SQLITE_ROW {
                    rows.append((string(statement, 0), Int(sqlite3_column_int64(statement, 1))))
                }
                return rows
            }
            stats.byApp = grouped("app_name").map { (name: $0.0.isEmpty ? String(localized: "Неизвестно") : $0.0, words: $0.1) }
            stats.byModel = grouped("model").map { (name: $0.0, words: $0.1) }
            let days = grouped("date(date, 'unixepoch', 'localtime')").sorted { $0.0 < $1.0 }
            stats.perDay = Self.fillDays(days, since: since, now: now)
        }
        return stats
    }

    /// Every day from the first (or `since`) to today, with 0 for days without dictation.
    static func fillDays(_ days: [(String, Int)], since: Date?, now: Date) -> [(day: String, words: Int)] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current
        guard let first = since.map({ calendar.startOfDay(for: $0) }) ?? days.first.flatMap({ formatter.date(from: $0.0) }) else { return [] }
        let words = Dictionary(days, uniquingKeysWith: +)
        var result: [(day: String, words: Int)] = []
        var day = first
        let end = calendar.startOfDay(for: now)
        while day <= end, result.count < 3700 {
            let key = formatter.string(from: day)
            result.append((key, words[key] ?? 0))
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return result
    }

    // MARK: - SQLite

    private func withDB(_ body: (OpaquePointer) -> Void) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let db else {
            Log.error("Cannot open the history at \(url.path)", "history")
            sqlite3_close(db)
            return
        }
        defer { sqlite3_close(db) }
        // Lowercase with Unicode rules (SQLite's lower() is ASCII only): for searching Russian text.
        sqlite3_create_function(db, "lower_ru", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { context, _, values in
            guard let values, let text = sqlite3_value_text(values[0]) else { sqlite3_result_null(context); return }
            let lowered = String(cString: text).lowercased()
            sqlite3_result_text(context, lowered, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }, nil, nil)
        body(db)
    }

    private func exec(_ db: OpaquePointer, _ sql: String) {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK { Log.error("SQL failed: \(String(cString: sqlite3_errmsg(db)))", "history") }
    }

    private func prepare(_ db: OpaquePointer, _ sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            Log.error("SQL prepare failed: \(String(cString: sqlite3_errmsg(db)))", "history")
        }
        return statement
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ text: String) {
        sqlite3_bind_text(statement, index, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func string(_ statement: OpaquePointer?, _ index: Int32) -> String {
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }
}
