import CommonCrypto
import Foundation

/// Who a Telegram voice message came from, read from Telegram's database by the helper
/// (`GeniusTyperEngine senders`) and kept with the text.
struct VoiceSender: Codable, Equatable, Sendable {
    /// The private chat's person, or the group's or channel's title.
    var chat: String
    /// Who sent it in a group (nil in private chats and for channel posts).
    var author: String? = nil
    /// The original author of a forwarded voice message.
    var forwardedFrom: String? = nil
    /// Sent by the owner.
    var outgoing: Bool

    /// One line for the row: "Кристина", "Вы → Кристина", "Иван · Семья", "Кристина · переслано от Ивана".
    var title: String {
        var line = outgoing ? String(localized: "Вы → \(chat)") : author.map { "\($0) · \(chat)" } ?? chat
        if let forwardedFrom { line += " · " + String(localized: "переслано от \(forwardedFrom)") }
        return line
    }
}

/// The parts of Telegram for macOS's database ("Postbox", SQLCipher, `postbox/db/db_sqlite`) needed
/// to tell who sent a voice message. Pure, so the app's tests check it; the helper, which links
/// SQLCipher, does the queries (`GeniusTyperEngine/TelegramSenders.swift`). The layout is Telegram's
/// own and undocumented (Telegram-iOS `submodules/Postbox`, checked 2026-10-29): when it changes,
/// voice messages simply show no sender.
///
/// - The database key is in `stable/.tempkeyEncrypted`, AES-256-CBC with SHA-512 of the local passcode,
///   "no-matter-key" when there is none (a passcode set in Telegram: no names).
/// - t6, media: key = namespace (Int32) + document id (Int64), big-endian; value of a media kept in
///   a message = 1 + the message's index (peer Int64, namespace Int32, id Int32, timestamp Int32,
///   little-endian). A media in several messages (forwarded to more chats) is stored on its own
///   (0 + the media) and the messages list its id (`referencePattern`).
/// - t7, messages: key = peer (Int64), namespace, timestamp, id (Int32), big-endian; value = flags,
///   forward info and author (`messageHeader`).
/// - t2, peers: key = peer id; value = a `PostboxEncoder` object with the name fields.
enum TelegramPostbox {
    static let mediaTable = "t6"
    static let messagesTable = "t7"
    static let peersTable = "t2"
    /// Telegram's `Namespaces.Media.CloudFile`: voice messages are documents.
    static let cloudFileNamespace: Int32 = 5

    /// The 48 bytes of the SQLCipher raw key (key + salt), or nil when the passcode is not the
    /// default one (the hash at the end does not match).
    static func databaseKey(tempkeyEncrypted data: Data, passcode: String = "no-matter-key") -> Data? {
        guard data.count == 64 else { return nil }
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
        let pass = Array(passcode.utf8)
        CC_SHA512(pass, CC_LONG(pass.count), &hash)
        var plain = [UInt8](repeating: 0, count: 64)
        var moved = 0
        let status = data.withUnsafeBytes { input in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0, Array(hash[0..<32]), 32, Array(hash[48..<64]),
                    input.baseAddress, 64, &plain, 64, &moved)
        }
        guard status == kCCSuccess, moved == 64 else { return nil }
        let keyAndSalt = Data(plain[0..<48])
        let check = UInt32(plain[48]) | UInt32(plain[49]) << 8 | UInt32(plain[50]) << 16 | UInt32(plain[51]) << 24
        return murmur3(keyAndSalt, seed: UInt32(bitPattern: -137_723_950)) == check ? keyAndSalt : nil
    }

    /// MurmurHash3 (x86, 32 bit), as Telegram's `murMurHash32`.
    static func murmur3(_ data: Data, seed: UInt32) -> UInt32 {
        let bytes = [UInt8](data)
        let c1: UInt32 = 0xcc9e_2d51, c2: UInt32 = 0x1b87_3593
        var h = seed
        let blocks = bytes.count / 4
        for i in 0..<blocks {
            var k = UInt32(bytes[i * 4]) | UInt32(bytes[i * 4 + 1]) << 8 | UInt32(bytes[i * 4 + 2]) << 16 | UInt32(bytes[i * 4 + 3]) << 24
            k = (k &* c1).rotatedLeft(15) &* c2
            h ^= k
            h = h.rotatedLeft(13) &* 5 &+ 0xe654_6b64
        }
        var k: UInt32 = 0
        let tail = bytes[(blocks * 4)...]
        let start = tail.startIndex
        if tail.count >= 3 { k ^= UInt32(tail[start + 2]) << 16 }
        if tail.count >= 2 { k ^= UInt32(tail[start + 1]) << 8 }
        if tail.count >= 1 {
            k ^= UInt32(tail[start])
            h ^= (k &* c1).rotatedLeft(15) &* c2
        }
        h ^= UInt32(truncatingIfNeeded: bytes.count)
        h ^= h >> 16
        h = h &* 0x85eb_ca6b
        h ^= h >> 13
        h = h &* 0xc2b2_ae35
        h ^= h >> 16
        return h
    }

    /// The document id in a cached file's name: "telegram-cloud-document-<datacenter>-<id>", some
    /// with an extension (".mp3", ".ogg").
    static func documentId(fileName: String) -> Int64? {
        let prefix = "telegram-cloud-document-"
        guard fileName.hasPrefix(prefix) else { return nil }
        let parts = fileName.dropFirst(prefix.count).split(separator: "-")
        guard parts.count == 2, Int(parts[0]) != nil else { return nil }
        return Int64(parts[1].prefix { $0 != "." })
    }

    static func mediaKey(documentId: Int64) -> Data {
        bigEndian(cloudFileNamespace) + bigEndian(documentId)
    }

    /// How a message lists a media stored on its own: namespace (Int32) + id (Int64), little-endian.
    static func referencePattern(documentId: Int64) -> Data {
        withUnsafeBytes(of: cloudFileNamespace.littleEndian) { Data($0) } + withUnsafeBytes(of: documentId.littleEndian) { Data($0) }
    }

    struct MessageIndex: Equatable {
        let peer: Int64
        let namespace: Int32
        let id: Int32
        let timestamp: Int32

        var key: Data { bigEndian(peer) + bigEndian(namespace) + bigEndian(timestamp) + bigEndian(id) }
    }

    /// A message's index from its key in t7.
    static func messageIndex(key: Data) -> MessageIndex? {
        guard key.count == 20 else { return nil }
        func integer<T: FixedWidthInteger>(_ at: Int, _: T.Type) -> T {
            key[(key.startIndex + at)..<(key.startIndex + at + MemoryLayout<T>.size)].reduce(T.zero) { $0 << 8 | T(truncatingIfNeeded: $1) }
        }
        return MessageIndex(peer: integer(0, Int64.self), namespace: integer(8, Int32.self), id: integer(16, Int32.self), timestamp: integer(12, Int32.self))
    }

    /// The message a media entry is kept in (nil: stored on its own, or unknown).
    static func messageIndex(media value: Data) -> MessageIndex? {
        var reader = Reader(value)
        guard reader.int8() == 1, let peer = reader.int64(), let namespace = reader.int32(),
              let id = reader.int32(), let timestamp = reader.int32() else { return nil }
        return MessageIndex(peer: peer, namespace: namespace, id: id, timestamp: timestamp)
    }

    struct MessageHeader: Equatable {
        let incoming: Bool
        let author: Int64?
        let forwardAuthor: Int64?
    }

    /// The start of a stored message (Postbox `readIntermediateEntry`).
    static func messageHeader(_ value: Data) -> MessageHeader? {
        var reader = Reader(value)
        guard reader.int8() == 0, reader.skip(8), let dataFlags = reader.int8() else { return nil }
        // Globally unique id, global tags, grouping key, group info, local tags, thread id.
        for (bit, size) in [(0, 8), (1, 4), (2, 8), (3, 4), (4, 4), (5, 8)] where dataFlags & (1 << bit) != 0 {
            guard reader.skip(size) else { return nil }
        }
        guard let flags = reader.int32(), reader.skip(4), let forward = reader.int8() else { return nil }
        var forwardAuthor: Int64?
        if forward != 0 {
            guard let author = reader.int64(), reader.skip(4) else { return nil }
            forwardAuthor = author == 0 ? nil : author
            if forward & (1 << 1) != 0 { guard reader.skip(8) else { return nil } }
            if forward & (1 << 2) != 0 { guard reader.skip(16) else { return nil } }
            for bit in [3, 4] where forward & (1 << bit) != 0 {
                guard let length = reader.int32(), length >= 0, reader.skip(Int(length)) else { return nil }
            }
            if forward & (1 << 5) != 0 { guard reader.skip(4) else { return nil } }
        }
        guard let hasAuthor = reader.int8() else { return nil }
        var author: Int64?
        if hasAuthor == 1 {
            guard let id = reader.int64() else { return nil }
            author = id
        }
        // `MessageFlags.Incoming`.
        return MessageHeader(incoming: flags & 4 != 0, author: author, forwardAuthor: forwardAuthor)
    }

    /// Users, groups, channels and secret chats ("Namespaces.Peer"), from a peer id's bits 32–34.
    static func isUser(_ peer: Int64) -> Bool { (peer >> 32) & 7 == 0 }

    /// A peer's name: "First Last" of a user, the title of a group or channel. The fields are
    /// found by their encoded key and type (string = 4), not by decoding the whole object.
    static func peerName(_ value: Data) -> String? {
        let first = string("fn", in: value), last = string("ln", in: value)
        let name = [first, last].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ")
        if !name.isEmpty { return name }
        if let title = string("t", in: value), !title.isEmpty { return title }
        return nil
    }

    /// A string field of a `PostboxEncoder` object: key length, key, type 4, Int32 length, UTF-8.
    static func string(_ key: String, in value: Data) -> String? {
        let pattern = Data([UInt8(key.utf8.count)] + Array(key.utf8) + [4])
        var from = value.startIndex
        while let found = value.range(of: pattern, in: from..<value.endIndex) {
            var reader = Reader(value[found.upperBound...])
            if let length = reader.int32(), length >= 0, length <= 1024, let bytes = reader.bytes(Int(length)),
               let text = String(data: bytes, encoding: .utf8) {
                return text
            }
            from = found.upperBound
        }
        return nil
    }

    private static func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    /// Little-endian reads that fail past the end.
    private struct Reader {
        private let data: Data
        private var offset: Int

        init(_ data: Data) {
            self.data = data
            offset = data.startIndex
        }

        mutating func bytes(_ count: Int) -> Data? {
            guard count >= 0, offset + count <= data.endIndex else { return nil }
            defer { offset += count }
            return data[offset..<offset + count]
        }

        mutating func skip(_ count: Int) -> Bool { bytes(count) != nil }

        mutating func int8() -> Int8? { bytes(1).map { Int8(bitPattern: $0.first!) } }
        mutating func int32() -> Int32? { integer() }
        mutating func int64() -> Int64? { integer() }

        private mutating func integer<T: FixedWidthInteger>() -> T? {
            guard let bytes = bytes(MemoryLayout<T>.size) else { return nil }
            return bytes.reversed().reduce(T.zero) { $0 << 8 | T(truncatingIfNeeded: $1) }
        }
    }
}

private extension UInt32 {
    func rotatedLeft(_ count: UInt32) -> UInt32 { self << count | self >> (32 - count) }
}
