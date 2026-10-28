// `GeniusTyperEngine senders <file>…`: who sent each Telegram voice message, from Telegram's own
// database (SQLCipher, opened read-only next to the running Telegram). Here and not in Genius
// Typer: SQLCipher brings its own sqlite3 symbols, and the app uses the system SQLite for the
// dictation history. The format is read by `TelegramPostbox` (shared with the app, tested there).
import Foundation
import SQLCipher

/// One `{"path", "chat", "author"?, "forwardedFrom"?, "outgoing"}` per file whose sender is found.
func telegramSenders(_ paths: [String]) -> [[String: Any]] {
    // …/stable/account-<id>/postbox/media/<file>: one database per account.
    let byAccount = Dictionary(grouping: paths) {
        URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
    }
    var result: [[String: Any]] = []
    for (account, files) in byAccount {
        let accountURL = URL(fileURLWithPath: account, isDirectory: true)
        guard let encrypted = try? Data(contentsOf: accountURL.deletingLastPathComponent().appendingPathComponent(".tempkeyEncrypted")),
              let key = TelegramPostbox.databaseKey(tempkeyEncrypted: encrypted),
              let database = TelegramDatabase(accountURL.appendingPathComponent("postbox/db/db_sqlite").path, key: key) else {
            FileHandle.standardError.write("no database key for \(account)\n".data(using: .utf8)!)
            continue
        }
        let senders = database.senders(fileNames: files.map { URL(fileURLWithPath: $0).lastPathComponent })
        for path in files {
            guard let sender = senders[URL(fileURLWithPath: path).lastPathComponent] else { continue }
            var line: [String: Any] = ["path": path, "chat": sender.chat, "outgoing": sender.outgoing]
            if let author = sender.author { line["author"] = author }
            if let forwardedFrom = sender.forwardedFrom { line["forwardedFrom"] = forwardedFrom }
            result.append(line)
        }
    }
    return result
}

private final class TelegramDatabase {
    private var db: OpaquePointer?

    init?(_ path: String, key: Data) {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        let hex = key.map { String(format: "%02x", $0) }.joined()
        // Telegram keeps the first 32 bytes of the file plain (iOS: so the system sees a SQLite file).
        guard sqlite3_exec(db, "PRAGMA key = \"x'\(hex)'\"; PRAGMA cipher_plaintext_header_size = 32;", nil, nil, nil) == SQLITE_OK else {
            return nil
        }
        sqlite3_busy_timeout(db, 2000)
    }

    deinit { sqlite3_close(db) }

    /// Senders by file name.
    func senders(fileNames: [String]) -> [String: VoiceSender] {
        var indices: [String: TelegramPostbox.MessageIndex] = [:]
        // Media stored on its own (in several messages): found by one pass over the messages.
        var shared: [String: Data] = [:]
        for fileName in fileNames {
            guard let document = TelegramPostbox.documentId(fileName: fileName),
                  let media = value("SELECT value FROM \(TelegramPostbox.mediaTable) WHERE key = ?", blob: TelegramPostbox.mediaKey(documentId: document)) else { continue }
            if let index = TelegramPostbox.messageIndex(media: media) {
                indices[fileName] = index
            } else {
                shared[fileName] = TelegramPostbox.referencePattern(documentId: document)
            }
        }
        if !shared.isEmpty {
            // ~0.4 s for ~90 000 messages; the newest message with the media wins.
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT key, value FROM \(TelegramPostbox.messagesTable)", -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let bytes = sqlite3_column_blob(statement, 1) else { continue }
                    let value = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes), count: Int(sqlite3_column_bytes(statement, 1)), deallocator: .none)
                    for (fileName, pattern) in shared where value.range(of: pattern) != nil {
                        guard let keyBytes = sqlite3_column_blob(statement, 0),
                              let index = TelegramPostbox.messageIndex(key: Data(bytes: keyBytes, count: Int(sqlite3_column_bytes(statement, 0)))),
                              index.timestamp >= indices[fileName]?.timestamp ?? .min else { continue }
                        indices[fileName] = index
                    }
                }
            }
            sqlite3_finalize(statement)
        }
        return indices.compactMapValues(sender)
    }

    private func sender(_ index: TelegramPostbox.MessageIndex) -> VoiceSender? {
        guard let chat = name(index.peer) else { return nil }
        let header = value("SELECT value FROM \(TelegramPostbox.messagesTable) WHERE key = ?", blob: index.key).flatMap(TelegramPostbox.messageHeader)
        let outgoing = header.map { !$0.incoming } ?? false
        // In a group the author differs from the chat; in a private chat the author is the person (or the owner).
        // A channel's post has the channel as its author, and a post the channel sends on to its own
        // chat is "forwarded" from that author: no names twice.
        let author = TelegramPostbox.isUser(index.peer) || outgoing ? nil : header?.author.flatMap(name).flatMap { $0 == chat ? nil : $0 }
        let forwardedFrom = header?.forwardAuthor.flatMap(name).flatMap { $0 == chat || $0 == author ? nil : $0 }
        return VoiceSender(chat: chat, author: author, forwardedFrom: forwardedFrom, outgoing: outgoing)
    }

    private func name(_ peer: Int64) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM \(TelegramPostbox.peersTable) WHERE key = ?", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, peer)
        return row(statement).flatMap(TelegramPostbox.peerName)
    }

    private func value(_ sql: String, blob: Data) -> Data? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(blob.count), transient) }
        return row(statement)
    }

    private func row(_ statement: OpaquePointer?) -> Data? {
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }
}
