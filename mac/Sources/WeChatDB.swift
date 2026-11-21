import CommonCrypto
import CryptoKit
import Foundation
import Security
import SQLite3

/// Read-only access to the user's own WeChat 4.x databases on this Mac.
/// Uses the database key that WeFlow already captured (stored in WeFlow's config, protected by the
/// "weflow Safe Storage" Keychain item). Databases are decrypted in memory only; nothing is written to disk
/// and nothing is ever written back to WeChat.
enum WeChatDB {
    static let pageSize = 4096
    static let reserve = 80  // 16-byte IV + 64-byte HMAC-SHA512 at the end of every page
    static let sqliteHeader = Data("SQLite format 3\0".utf8)

    enum Failure: LocalizedError {
        case msg(String)
        var errorDescription: String? { if case .msg(let m) = self { return m }; return nil }
    }

    struct Account {
        let storage: URL   // .../xwechat_files/<wxid_xxx>/db_storage
        let myWxid: String // normalized, e.g. wxid_abc (without the 4-char folder suffix)
        let rawKey: Data
        let derive: Bool   // false: rawKey is the page key; true: PBKDF2(rawKey, salt) per database
    }

    // MARK: key

    private static let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/weflow/WeFlow-config.json")

    private static var cachedAccount: Account?

    static func account() throws -> Account {
        if let a = cachedAccount { return a }
        guard let data = try? Data(contentsOf: configURL),
              let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Failure.msg("没找到 WeFlow 的配置（需要它之前取到的数据库密钥）。") }
        guard let dbPath = cfg["dbPath"] as? String, let folder = cfg["myWxid"] as? String, !folder.isEmpty
        else { throw Failure.msg("WeFlow 配置里没有微信数据目录。") }
        let storage = URL(fileURLWithPath: dbPath).appendingPathComponent(folder).appendingPathComponent("db_storage")
        guard FileManager.default.fileExists(atPath: storage.appendingPathComponent("session/session.db").path)
        else { throw Failure.msg("找不到微信数据库：\(storage.path)") }

        var stored = cfg["decryptKey"] as? String ?? ""
        if let wc = cfg["wxidConfigs"] as? [String: Any], let mine = wc[folder] as? [String: Any],
           let k = mine["decryptKey"] as? String, !k.isEmpty { stored = k }
        let hex = try unprotect(stored).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Data(hexString: hex), raw.count == 32 else { throw Failure.msg("WeFlow 里存的密钥格式不对。") }

        // Decide how the key is used by checking page 1's HMAC of session.db.
        let page1 = try readPrefix(storage.appendingPathComponent("session/session.db"), count: pageSize)
        let derive: Bool
        if verifyPage(page1, pgno: 1, encKey: raw) { derive = false }
        else if verifyPage(page1, pgno: 1, encKey: pbkdf2SHA512(raw, salt: page1.prefix(16), rounds: 256_000)) { derive = true }
        else { throw Failure.msg("密钥对不上当前的微信数据库（可能重新登录过微信）。需要重新取一次密钥。") }

        let a = Account(storage: storage, myWxid: normalizeWxid(folder), rawKey: raw, derive: derive)
        cachedAccount = a
        return a
    }

    static func normalizeWxid(_ s: String) -> String {
        if s.lowercased().hasPrefix("wxid_"), let r = s.range(of: #"^wxid_[^_]+"#, options: .regularExpression) {
            return String(s[r])
        }
        if let r = s.range(of: #"_[a-zA-Z0-9]{4}$"#, options: .regularExpression) { return String(s[..<r.lowerBound]) }
        return s
    }

    /// Undo Electron safeStorage ("safe:" + base64 of "v10" + AES-128-CBC) using the app's Keychain password.
    /// macOS asks the user once whether WeChatCoach may read the "weflow Safe Storage" item.
    private static func unprotect(_ s: String) throws -> String {
        guard s.hasPrefix("safe:") else { return s }
        guard let blob = Data(base64Encoded: String(s.dropFirst(5))), blob.count > 3,
              blob.prefix(3) == Data("v10".utf8)
        else { throw Failure.msg("WeFlow 密钥的加密格式不认识。") }
        var password: Data?
        for service in ["weflow Safe Storage", "WeFlow Safe Storage"] {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            var out: AnyObject?
            let st = SecItemCopyMatching(q as CFDictionary, &out)
            if st == errSecSuccess, let d = out as? Data { password = d; break }
            if st == errSecUserCanceled || st == errSecAuthFailed {
                throw Failure.msg("没有允许读取钥匙串里的「weflow Safe Storage」，所以解不开密钥。")
            }
        }
        guard let password else { throw Failure.msg("钥匙串里没有 WeFlow 的密钥项（weflow Safe Storage）。") }
        let key = pbkdf2SHA1(password, salt: Data("saltysalt".utf8), rounds: 1003, length: 16)
        let plain = try aesCBC(blob.dropFirst(3), key: key, iv: Data(repeating: 0x20, count: 16), padding: true)
        guard let str = String(data: plain, encoding: .utf8) else { throw Failure.msg("WeFlow 密钥解密失败。") }
        return str
    }

    // MARK: crypto helpers

    static func pbkdf2SHA512(_ pass: Data, salt: Data, rounds: UInt32, length: Int = 32) -> Data {
        pbkdf2(pass, salt: salt, rounds: rounds, length: length, prf: CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512))
    }

    static func pbkdf2SHA1(_ pass: Data, salt: Data, rounds: UInt32, length: Int) -> Data {
        pbkdf2(pass, salt: salt, rounds: rounds, length: length, prf: CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1))
    }

    private static func pbkdf2(_ pass: Data, salt: Data, rounds: UInt32, length: Int, prf: CCPseudoRandomAlgorithm) -> Data {
        var out = Data(count: length)
        let passArr = [UInt8](pass), saltArr = [UInt8](salt)
        out.withUnsafeMutableBytes { o in
            _ = passArr.withUnsafeBufferPointer { p in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), UnsafeRawPointer(p.baseAddress!).assumingMemoryBound(to: Int8.self),
                                     passArr.count, saltArr, saltArr.count, prf, rounds,
                                     o.bindMemory(to: UInt8.self).baseAddress!, length)
            }
        }
        return out
    }

    static func aesCBC(_ input: Data, key: Data, iv: Data, padding: Bool) throws -> Data {
        var out = Data(count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let inArr = [UInt8](input), keyArr = [UInt8](key), ivArr = [UInt8](iv)
        let outCount = out.count
        let st = out.withUnsafeMutableBytes { o in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(padding ? kCCOptionPKCS7Padding : 0),
                    keyArr, keyArr.count, ivArr, inArr, inArr.count, o.baseAddress, outCount, &moved)
        }
        guard st == kCCSuccess else { throw Failure.msg("AES 解密失败（\(st)）") }
        return out.prefix(moved)
    }

    private static func macKey(_ encKey: Data, salt: Data) -> Data {
        pbkdf2SHA512(encKey, salt: Data(salt.map { $0 ^ 0x3a }), rounds: 2)
    }

    /// SQLCipher 4 page check: HMAC-SHA512 over (ciphertext + IV + page number LE).
    static func verifyPage(_ page: Data, pgno: UInt32, encKey: Data, macKey mk: Data? = nil, salt: Data? = nil) -> Bool {
        guard page.count >= pageSize else { return false }
        let p = Data(page.prefix(pageSize))
        let s = salt ?? p.prefix(16)
        let key = mk ?? macKey(encKey, salt: s)
        let start = pgno == 1 ? 16 : 0
        var msg = p.subdata(in: start..<(pageSize - 64))
        var n = pgno.littleEndian
        msg.append(Data(bytes: &n, count: 4))
        let mac = Data(HMAC<SHA512>.authenticationCode(for: msg, using: SymmetricKey(data: key)))
        return mac == p.subdata(in: (pageSize - 64)..<pageSize)
    }

    private static func decryptPage(_ page: Data, pgno: UInt32, encKey: Data) throws -> Data {
        let p = Data(page)
        let start = pgno == 1 ? 16 : 0
        let iv = p.subdata(in: (pageSize - reserve)..<(pageSize - reserve + 16))
        var out = pgno == 1 ? sqliteHeader : Data()
        out.append(try aesCBC(p.subdata(in: start..<(pageSize - reserve)), key: encKey, iv: iv, padding: false))
        out.append(Data(count: reserve))
        return out
    }

    private static func readPrefix(_ url: URL, count: Int) throws -> Data {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        return h.readData(ofLength: count)
    }

    // MARK: decrypt to an in-memory SQLite handle

    final class Handle {
        let db: OpaquePointer
        init(_ db: OpaquePointer) { self.db = db }
        deinit { sqlite3_close(db) }
    }

    private static var cache: [String: (stamp: String, handle: Handle)] = [:]
    private static var keyCache: [String: (salt: Data, enc: Data, mac: Data)] = [:]

    private static func stamp(_ url: URL) -> String {
        [url.path, url.path + "-wal"].map { p -> String in
            let a = try? FileManager.default.attributesOfItem(atPath: p)
            return "\((a?[.size] as? Int) ?? -1)@\(((a?[.modificationDate] as? Date)?.timeIntervalSince1970) ?? 0)"
        }.joined(separator: "|")
    }

    /// Decrypts `rel` (e.g. "session/session.db") plus its -wal into memory and opens it read-only.
    static func open(_ rel: String) throws -> Handle {
        let acct = try account()
        let url = acct.storage.appendingPathComponent(rel)
        let st = stamp(url)
        if let c = cache[rel], c.stamp == st { return c.handle }

        let enc = try Data(contentsOf: url, options: .mappedIfSafe)
        guard enc.count >= pageSize else { throw Failure.msg("\(rel) 太小") }
        let salt = Data(enc.prefix(16))
        let encKey: Data, mk: Data
        if let k = keyCache[rel], k.salt == salt { (encKey, mk) = (k.enc, k.mac) } else {
            encKey = acct.derive ? pbkdf2SHA512(acct.rawKey, salt: salt, rounds: 256_000) : acct.rawKey
            mk = macKey(encKey, salt: salt)
            keyCache[rel] = (salt, encKey, mk)
        }

        var plain = Data(capacity: enc.count)
        let pages = enc.count / pageSize
        for i in 0..<pages {
            let page = enc.subdata(in: (i * pageSize)..<((i + 1) * pageSize))
            if page.allSatisfy({ $0 == 0 }) { plain.append(page); continue }  // never-written page
            plain.append(try decryptPage(page, pgno: UInt32(i + 1), encKey: encKey))
        }

        // Apply committed WAL frames (newest messages usually live here until WeChat checkpoints).
        if let wal = try? Data(contentsOf: URL(fileURLWithPath: url.path + "-wal"), options: .mappedIfSafe), wal.count > 32 {
            func be32(_ d: Data, _ o: Int) -> UInt32 { d.subdata(in: o..<(o + 4)).reduce(0) { $0 << 8 | UInt32($1) } }
            let walSalt1 = be32(wal, 16), walSalt2 = be32(wal, 20)
            let frameSize = 24 + pageSize
            var frames: [(pgno: UInt32, commit: UInt32, data: Data)] = []
            var off = 32
            var lastCommit = -1
            while off + frameSize <= wal.count {
                let pgno = be32(wal, off), commit = be32(wal, off + 4)
                guard be32(wal, off + 8) == walSalt1, be32(wal, off + 12) == walSalt2, pgno > 0 else { break }
                let data = wal.subdata(in: (off + 24)..<(off + frameSize))
                guard verifyPage(data, pgno: pgno, encKey: encKey, macKey: mk, salt: salt) else { break }
                frames.append((pgno, commit, data))
                if commit != 0 { lastCommit = frames.count - 1 }
                off += frameSize
            }
            if lastCommit >= 0 {
                for f in frames[0...lastCommit] {
                    let dec = try decryptPage(f.data, pgno: f.pgno, encKey: encKey)
                    let o = Int(f.pgno - 1) * pageSize
                    if o + pageSize > plain.count { plain.append(Data(count: o + pageSize - plain.count)) }
                    plain.replaceSubrange(o..<(o + pageSize), with: dec)
                }
                let size = Int(frames[lastCommit].commit) * pageSize
                if size > 0 && size < plain.count { plain.removeSubrange(size..<plain.count) }
            }
        }
        // Header bytes 18/19 = 2 means WAL mode; an in-memory copy must be a plain rollback-journal database.
        plain[18] = 1
        plain[19] = 1

        var db: OpaquePointer?
        guard sqlite3_open_v2(":memory:", &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw Failure.msg("SQLite 打开失败")
        }
        let n = plain.count
        guard let buf = sqlite3_malloc64(sqlite3_uint64(n)) else { sqlite3_close(db); throw Failure.msg("内存不足") }
        plain.copyBytes(to: buf.assumingMemoryBound(to: UInt8.self), count: n)
        let rc = sqlite3_deserialize(db, "main", buf.assumingMemoryBound(to: UInt8.self), sqlite3_int64(n), sqlite3_int64(n),
                                     UInt32(SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_READONLY))
        guard rc == SQLITE_OK else { sqlite3_close(db); throw Failure.msg("解密后的 \(rel) 打不开（\(rc)）") }
        let h = Handle(db)
        cache[rel] = (st, h)
        return h
    }

    // MARK: query helpers

    typealias Row = [String: Any]

    static func query(_ h: Handle, _ sql: String, _ args: [Any] = []) throws -> [Row] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(h.db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw Failure.msg("SQL 错误：\(String(cString: sqlite3_errmsg(h.db)))")
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() {
            switch a {
            case let v as Int: sqlite3_bind_int64(stmt, Int32(i + 1), sqlite3_int64(v))
            case let v as String: sqlite3_bind_text(stmt, Int32(i + 1), v, -1, transient)
            default: sqlite3_bind_null(stmt, Int32(i + 1))
            }
        }
        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var r: Row = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: r[name] = Int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: r[name] = sqlite3_column_double(stmt, c)
                case SQLITE_TEXT: r[name] = String(cString: sqlite3_column_text(stmt, c))
                case SQLITE_BLOB:
                    let len = Int(sqlite3_column_bytes(stmt, c))
                    r[name] = len > 0 ? Data(bytes: sqlite3_column_blob(stmt, c), count: len) : Data()
                default: break
                }
            }
            rows.append(r)
        }
        return rows
    }

    static func tables(_ h: Handle) throws -> [String] {
        try query(h, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").compactMap { $0["name"] as? String }
    }

    static func columns(_ h: Handle, _ table: String) throws -> [String] {
        try query(h, "PRAGMA table_info(\"\(table)\")").compactMap { $0["name"] as? String }
    }

    static func messageDBs() throws -> [String] {
        let dir = try account().storage.appendingPathComponent("message")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.range(of: #"^message_\d+\.db$"#, options: .regularExpression) != nil }
            .sorted { Int($0.filter(\.isNumber))! > Int($1.filter(\.isNumber))! }
            .map { "message/\($0)" }
    }

    // MARK: sessions & messages

    struct Session {
        let username: String
        let displayName: String
        let lastTimestamp: Int
        let unreadCount: Int
    }

    struct Message {
        let localId: Int
        let createTime: Int
        let sortSeq: Int
        let isSend: Bool
        let type: Int
        let content: String
        let sender: String
    }

    static let systemUsernames: Set<String> = [
        "filehelper", "weixin", "fmessage", "medianote", "floatbottle", "qqmail", "notifymessage",
        "newsapp", "brandsessionholder", "brandservicesessionholder", "opencustomerservicemsg", "qqsafe",
        "tmessage", "officialaccounts", "notification_messages", "mphelper", "@placeholder_foldgroup",
    ]

    static func isPrivateChat(_ u: String) -> Bool {
        let l = u.lowercased()
        return !l.contains("@") && !l.hasPrefix("gh_") && !systemUsernames.contains(l) && !l.isEmpty
    }

    static func displayNames(_ users: [String]) throws -> [String: String] {
        guard !users.isEmpty else { return [:] }
        let h = try open("contact/contact.db")
        var out: [String: String] = [:]
        for chunk in stride(from: 0, to: users.count, by: 400).map({ Array(users[$0..<min($0 + 400, users.count)]) }) {
            let marks = chunk.map { _ in "?" }.joined(separator: ",")
            for r in try query(h, "SELECT username, remark, nick_name FROM contact WHERE username IN (\(marks))", chunk) {
                guard let u = r["username"] as? String else { continue }
                let remark = (r["remark"] as? String) ?? "", nick = (r["nick_name"] as? String) ?? ""
                out[u] = !remark.isEmpty ? remark : (!nick.isEmpty ? nick : u)
            }
        }
        return out
    }

    /// Private chats, most recent first.
    static func sessions(limit: Int = 300) throws -> [Session] {
        let h = try open("session/session.db")
        let rows = try query(h, """
            SELECT username, unread_count, last_timestamp, sort_timestamp FROM SessionTable
            WHERE is_hidden = 0 ORDER BY sort_timestamp DESC LIMIT ?
            """, [limit * 2])
        let users = rows.compactMap { $0["username"] as? String }.filter(isPrivateChat)
        let names = try displayNames(users)
        return rows.compactMap { r -> Session? in
            guard let u = r["username"] as? String, isPrivateChat(u) else { return nil }
            return Session(username: u, displayName: names[u] ?? u,
                           lastTimestamp: (r["last_timestamp"] as? Int) ?? 0, unreadCount: (r["unread_count"] as? Int) ?? 0)
        }.prefix(limit).map { $0 }
    }

    static func md5Hex(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The latest `limit` messages with `talker`, oldest → newest. Messages may be split across message_N.db files.
    static func messages(talker: String, limit: Int) throws -> [Message] {
        let acct = try account()
        let table = "Msg_" + md5Hex(talker)
        var all: [Message] = []
        for rel in try messageDBs() {
            let h = try open(rel)
            guard try !query(h, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", [table]).isEmpty else { continue }
            var senders: [Int: String] = [:]
            for r in try query(h, "SELECT rowid AS id, user_name FROM Name2Id") {
                if let id = r["id"] as? Int, let n = r["user_name"] as? String { senders[id] = n }
            }
            let rows = try query(h, """
                SELECT local_id, local_type, sort_seq, real_sender_id, create_time, status, message_content
                FROM "\(table)" ORDER BY sort_seq DESC LIMIT ?
                """, [limit])
            for r in rows {
                let sender = senders[(r["real_sender_id"] as? Int) ?? -1] ?? ""
                let isSend = sender.isEmpty ? ((r["status"] as? Int) == 2) : (normalizeWxid(sender) == acct.myWxid || sender == acct.myWxid)
                all.append(Message(localId: (r["local_id"] as? Int) ?? 0, createTime: (r["create_time"] as? Int) ?? 0,
                                   sortSeq: (r["sort_seq"] as? Int) ?? 0, isSend: isSend,
                                   type: ((r["local_type"] as? Int) ?? 0) & 0xFFFF_FFFF,
                                   content: text(of: r["message_content"]), sender: sender))
            }
        }
        all.sort { ($0.sortSeq, $0.createTime) < ($1.sortSeq, $1.createTime) }
        return Array(all.suffix(limit))
    }

    /// message_content is TEXT, or a BLOB that may be zstd-compressed (WCDB compression).
    private static func text(of value: Any?) -> String {
        if let s = value as? String { return s }
        guard let d = value as? Data, !d.isEmpty else { return "" }
        if d.prefix(4) == Data([0x28, 0xB5, 0x2F, 0xFD]) { return zstdDecompress(d) ?? "" }
        return String(data: d, encoding: .utf8) ?? ""
    }

    private static let zstdPath = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    private static func zstdDecompress(_ d: Data) -> String? {
        guard let zstdPath else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: zstdPath)
        p.arguments = ["-dcq"]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        DispatchQueue.global().async {
            inPipe.fileHandleForWriting.write(d)
            try? inPipe.fileHandleForWriting.close()
        }
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: out, encoding: .utf8)
    }

    /// Schema-only report for debugging: table names, columns and row counts. No message content.
    static func diagnose() throws -> String {
        let t0 = Date()
        let acct = try account()
        var out = "[db] key ok (mode: \(acct.derive ? "pbkdf2" : "raw")), me=\(acct.myWxid.prefix(9))…\n"
        for rel in ["session/session.db", "contact/contact.db"] + (try messageDBs()) {
            let t = Date()
            let h = try open(rel)
            let ts = try tables(h)
            let msgTables = ts.filter { $0.hasPrefix("Msg_") }
            out += String(format: "\n[%@] %.2fs, %d tables (%d Msg_*)\n", rel, Date().timeIntervalSince(t), ts.count, msgTables.count)
            for name in ts where !name.hasPrefix("Msg_") {
                let n = (try? query(h, "SELECT count(*) AS n FROM \"\(name)\""))?.first?["n"] as? Int ?? -1
                out += "  \(name) (\(n) rows): \((try? columns(h, name))?.joined(separator: ",") ?? "")\n"
            }
            if let m = msgTables.first {
                out += "  Msg_* columns: \((try? columns(h, m))?.joined(separator: ",") ?? "")\n"
            }
        }
        out += String(format: "\n[db] total %.2fs\n", Date().timeIntervalSince(t0))
        return out
    }
}

extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var d = Data(capacity: hexString.count / 2)
        var i = hexString.startIndex
        while i < hexString.endIndex {
            let j = hexString.index(i, offsetBy: 2)
            guard let b = UInt8(hexString[i..<j], radix: 16) else { return nil }
            d.append(b)
            i = j
        }
        self = d
    }
}
