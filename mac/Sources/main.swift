import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
import Security
import Vision

// MARK: - Errors

enum CoachError: LocalizedError {
    case noWindow
    case noKey
    case http(Int, String)
    case api(String)
    case refusal
    case weflow(String)
    case noContact

    var errorDescription: String? {
        switch self {
        case .noWindow: return "没找到微信窗口：请把微信聊天窗口留在屏幕上（不要最小化）。"
        case .noKey: return "还没设置 API Key。"
        case .http(let code, let body): return "API 请求失败（HTTP \(code)）：\(body.prefix(300))"
        case .api(let msg): return "API 错误：\(msg)"
        case .refusal: return "这次请求被模型拒绝了，没有给出建议。"
        case .weflow(let msg): return "聊天记录：\(msg)"
        case .noContact: return "先在上方选一个聊天对象（或在微信里打开聊天后按 ⌥⌘G 呼出，会自动选中）。"
        }
    }
}

// MARK: - Settings (defaults write local.wechatcoach <key> ...)

enum Settings {
    /// How many recent messages to send. Override: defaults write local.wechatcoach history -int 200
    static var historyCount: Int {
        let n = UserDefaults.standard.integer(forKey: "history")
        return n > 0 ? min(n, 1000) : 150
    }
    /// Model effort for the CLI / API. Override: defaults write local.wechatcoach effort low|medium|high
    static var effort: String {
        let e = UserDefaults.standard.string(forKey: "effort") ?? ""
        return ["low", "medium", "high"].contains(e) ? e : "medium"
    }

    static func note(for key: String) -> String {
        (UserDefaults.standard.dictionary(forKey: "notes") as? [String: String])?[key] ?? ""
    }

    static func setNote(_ note: String, for key: String) {
        var all = (UserDefaults.standard.dictionary(forKey: "notes") as? [String: String]) ?? [:]
        all[key] = note.isEmpty ? nil : note
        UserDefaults.standard.set(all, forKey: "notes")
    }
}

// MARK: - API key storage (env var first, then Keychain)

enum KeyStore {
    static let service = "WeChatCoach.anthropic"

    static func load() -> String? {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty { return env }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { return nil }
        return key
    }

    static func save(_ key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - Chat history source: the user's own WeChat database, read locally (see WeChatDB.swift)

typealias WeFlowSession = WeChatDB.Session
typealias WeFlowMessage = WeChatDB.Message

enum WeFlow {
    /// All database work happens on one serial queue (WeChatDB keeps in-memory caches).
    private static let queue = DispatchQueue(label: "wechatcoach.db")

    private static func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try work()) } catch {
                    cont.resume(throwing: CoachError.weflow((error as? LocalizedError)?.errorDescription ?? "\(error)"))
                }
            }
        }
    }

    /// Loads (and caches) the key; the first call may show the Keychain prompt.
    static func prepare() async throws { _ = try await run { try WeChatDB.account() } }

    private(set) static var isConfigured = false
    static func markReady(_ ok: Bool) { isConfigured = ok }

    static func sessions() async throws -> [WeFlowSession] { try await run { try WeChatDB.sessions() } }

    static func messages(talker: String, limit: Int) async throws -> [WeFlowMessage] {
        try await run { try WeChatDB.messages(talker: talker, limit: limit) }
    }

    /// First `<tag>…</tag>` value in WeChat's XML, with CDATA and entities removed.
    private static func xml(_ s: String, _ tag: String) -> String? {
        guard let r = s.range(of: "<\(tag)>([\\s\\S]*?)</\(tag)>", options: .regularExpression) else { return nil }
        var v = String(s[r]).replacingOccurrences(of: "<\(tag)>", with: "").replacingOccurrences(of: "</\(tag)>", with: "")
        v = v.replacingOccurrences(of: "<![CDATA[", with: "").replacingOccurrences(of: "]]>", with: "")
        for (a, b) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&amp;", "&")] {
            v = v.replacingOccurrences(of: a, with: b)
        }
        v = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    static func describe(_ m: WeFlowMessage) -> String? {
        let raw = m.content
        let text = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        func clip(_ s: String, _ n: Int = 300) -> String {
            let one = s.replacingOccurrences(of: "\n", with: " ")
            return one.count > n ? String(one.prefix(n)) + "…" : one
        }
        switch m.type {
        case 1: return text.isEmpty ? nil : clip(text)
        case 3: return "[图片]"
        case 34: return "[语音]"
        case 43: return "[视频]"
        case 47: return "[表情]"
        case 48: return "[位置] " + clip(xml(raw, "label") ?? xml(raw, "poiname") ?? "", 60)
        case 42: return "[名片]"
        case 50: return "[语音/视频通话]"
        case 49:
            // App messages: quote replies, links, files, transfers, red packets, mini programs…
            let title = xml(raw, "title").map { clip($0, 200) } ?? ""
            switch Int(xml(raw, "type") ?? "") ?? 0 {
            case 57:
                let quoted = xml(raw, "content").map { $0.contains("<") ? "" : "（引用：\(clip($0, 60))）" } ?? ""
                return title + quoted
            case 5: return "[链接] \(title)"
            case 6: return "[文件] \(title)"
            case 19: return "[聊天记录] \(title)"
            case 2000: return "[转账] \(xml(raw, "feedesc") ?? "")"
            case 2001: return "[红包] \(title)"
            case 33, 36: return "[小程序] \(title)"
            case 51: return "[视频号] \(title)"
            case 3: return "[音乐] \(title)"
            case 4: return "[视频链接] \(title)"
            case 62: return "[拍一拍]"
            default: return title.isEmpty ? "[分享]" : "[分享] \(title)"
            }
        case 10000, 10002:
            // System notices (recalls, pats, …); strip any XML.
            let plain = raw.contains("<") ? (xml(raw, "content") ?? xml(raw, "replacemsg") ?? "") : text
            let cleaned = plain.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            return cleaned.isEmpty ? nil : "（系统提示：\(clip(cleaned, 80))）"
        default: return raw.hasPrefix("<") ? "[其他消息]" : (text.isEmpty ? "[其他消息]" : clip(text, 200))
        }
    }

    /// Plain-text transcript the coach reads. Speakers come straight from the database, never guessed.
    static func transcript(_ msgs: [WeFlowMessage], name: String, note: String) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "zh_CN")
        day.dateFormat = "M月d日 EEE"
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        var out = "聊天对象：\(name)（下面「对方」就是 TA）\n"
        if !note.isEmpty { out += "背景补充：\(note)\n" }
        out += "\n最近 \(msgs.count) 条微信消息，按时间从早到晚：\n"
        var lastDay = ""
        for m in msgs {
            guard let body = describe(m) else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(m.createTime))
            let d = day.string(from: date)
            if d != lastDay { out += "\n—— \(d) ——\n"; lastDay = d }
            out += "\(clock.string(from: date)) \(m.isSend ? "我" : "对方")：\(body)\n"
        }
        let now = Date()
        let full = DateFormatter()
        full.locale = Locale(identifier: "zh_CN")
        full.dateFormat = "M月d日 EEE HH:mm"
        out += "\n现在是 \(full.string(from: now))。"
        if let last = msgs.last {
            let mins = Int(now.timeIntervalSince1970) - last.createTime
            let ago = mins < 3600 ? "\(max(mins / 60, 0)) 分钟" : (mins < 86400 ? "\(mins / 3600) 小时" : "\(mins / 86400) 天")
            out += "最后一条是\(last.isSend ? "我" : "对方")发的，距今约 \(ago)。"
            out += last.isSend ? "对方还没回。帮我判断要不要再发、发什么、什么时候发。" : "帮我看下一句怎么回。"
        }
        return out
    }
}

// MARK: - WeChat window capture + local OCR (used to detect the open chat, and as a fallback source)

enum WeChatCapture {
    static let bundleIDs: Set<String> = ["com.tencent.xinWeChat"]

    @MainActor
    static func findWindow() async throws -> SCWindow {
        // Include off-screen windows too: WeChat is often in its own full-screen Space or another desktop.
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let candidates = content.windows.filter { w in
            guard let app = w.owningApplication, bundleIDs.contains(app.bundleIdentifier) else { return false }
            guard w.windowLayer == 0, w.frame.width >= 400, w.frame.height >= 300 else { return false }
            // SCContentFilter asserts if the window rect touches no display; skip such windows.
            return content.displays.contains { $0.frame.intersects(w.frame) }
        }
        let pool = candidates.contains(where: { $0.isOnScreen }) ? candidates.filter { $0.isOnScreen } : candidates
        guard let win = pool.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else { throw CoachError.noWindow }
        return win
    }

    @MainActor  // SCContentFilter init asserts inside SkyLight when called off the main thread
    static func capture() async throws -> CGImage {
        let win = try await findWindow()
        let filter = SCContentFilter(desktopIndependentWindow: win)
        let cfg = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        cfg.width = Int(win.frame.width * scale)
        cfg.height = Int(win.frame.height * scale)
        cfg.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    /// OCR of the chat title bar (top of the right pane). Local only.
    static func titleText(_ image: CGImage) -> [String] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["zh-Hans", "en-US"]
        req.usesLanguageCorrection = false
        req.regionOfInterest = CGRect(x: 0.28, y: 0.88, width: 0.72, height: 0.12)  // origin bottom-left
        try? VNImageRequestHandler(cgImage: image).perform([req])
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    /// Which session is open in WeChat right now, by matching the title bar against WeFlow display names.
    @MainActor
    static func openChat(in sessions: [WeFlowSession]) async -> WeFlowSession? {
        guard let img = try? await capture() else { return nil }
        let lines = titleText(img).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 1 }
        var best: (WeFlowSession, Int)?
        for s in sessions {
            let name = s.displayName
            for line in lines {
                // The title may carry a suffix like "(2)" or be slightly truncated by the window width.
                let hit = line == name || line.hasPrefix(name) || (line.count >= 2 && name.hasPrefix(line))
                if hit, name.count > (best?.1 ?? 0) { best = (s, name.count) }
            }
        }
        return best?.0
    }

    static func jpegData(_ image: CGImage, maxSide: CGFloat = 1600) -> Data? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let ratio = min(1, maxSide / max(w, h))
        let tw = Int(w * ratio), th = Int(h * ratio)
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let scaled = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}

// MARK: - Claude Messages API (raw HTTP + SSE streaming; Swift has no official SDK)

enum Claude {
    static let model = "claude-opus-5-5"

    static func textContent(_ text: String) -> [[String: Any]] { [["type": "text", "text": text]] }

    static func screenshotContent(jpeg: Data, note: String) -> [[String: Any]] {
        var text = "这是我和对方的微信聊天截图，帮我看下一句怎么回。"
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { text += "\n背景补充：\(trimmed)" }
        return [
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]],
            ["type": "text", "text": text],
        ]
    }

    /// Bundle Resources/prompt/*.md concatenated in filename order (狗头军师 core → references → realtime rules).
    static func loadSystemPrompt() -> String {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("prompt"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return "" }
        return files.filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n\n---\n\n")
    }

    /// Streams one assistant turn for `messages`. Returns the assistant content blocks (thinking blocks
    /// included, unchanged) so the caller can append them to the history as-is.
    static func streamTurn(key: String, system: String, messages: [[String: Any]],
                           onText: @escaping @MainActor (String) -> Void) async throws -> [[String: Any]] {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "stream": true,
            "output_config": ["effort": Settings.effort],
            "fallbacks": "default",
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "messages": messages,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            var errBody = ""
            for try await line in bytes.lines { errBody += line }
            throw CoachError.http(status, errBody)
        }

        var stopReason: String?
        var blocks: [Int: [String: Any]] = [:]
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            switch type {
            case "content_block_start":
                if let i = obj["index"] as? Int, let block = obj["content_block"] as? [String: Any] { blocks[i] = block }
            case "content_block_delta":
                guard let i = obj["index"] as? Int, let delta = obj["delta"] as? [String: Any],
                      var block = blocks[i] else { break }
                func appendField(_ field: String) {
                    block[field] = (block[field] as? String ?? "") + (delta[field] as? String ?? "")
                }
                switch delta["type"] as? String {
                case "text_delta": appendField("text")
                case "thinking_delta": appendField("thinking")
                case "signature_delta": appendField("signature")
                default: break
                }
                blocks[i] = block
                if delta["type"] as? String == "text_delta", let text = delta["text"] as? String { await onText(text) }
            case "message_delta":
                if let delta = obj["delta"] as? [String: Any], let sr = delta["stop_reason"] as? String {
                    stopReason = sr
                }
            case "error":
                let msg = ((obj["error"] as? [String: Any])?["message"] as? String) ?? payload
                throw CoachError.api(msg)
            default:
                break
            }
        }
        if stopReason == "refusal" { throw CoachError.refusal }
        var content = blocks.keys.sorted().compactMap { blocks[$0] }
        // After a server-side fallback, model-internal blocks before the fallback marker must not be echoed back.
        if let lastFallback = content.lastIndex(where: { $0["type"] as? String == "fallback" }) {
            content = content.enumerated().filter { i, b in
                i > lastFallback || b["type"] as? String == "text"
            }.map { $0.element }.filter { $0["type"] as? String != "fallback" }
        }
        return content
    }
}

/// One coaching conversation: the first turn carries the chat history, later turns are follow-up questions.
@MainActor
protocol CoachConversation: AnyObject {
    func send(_ content: [[String: Any]], onText: @escaping @MainActor (String) -> Void) async throws
    func close()
}

@MainActor
final class APIConversation: CoachConversation {
    private let key: String
    private let system: String
    private var messages: [[String: Any]] = []  // append-only history

    init(key: String, system: String) {
        self.key = key
        self.system = system
    }

    func send(_ content: [[String: Any]], onText: @escaping @MainActor (String) -> Void) async throws {
        messages.append(["role": "user", "content": content])
        do {
            let reply = try await Claude.streamTurn(key: key, system: system, messages: messages, onText: onText)
            messages.append(["role": "assistant", "content": reply])
        } catch {
            messages.removeLast()  // nothing was answered; let the user retry the same turn
            throw error
        }
    }

    func close() {}
}

// MARK: - Claude Code CLI backend (uses the user's logged-in `claude` subscription, no API key)

enum ClaudeCLI {
    static func executable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          "\(home)/.claude/local/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Keeps one `claude -p` process alive per conversation; each follow-up is another stream-json user line.
@MainActor
final class CLIConversation: CoachConversation {
    private let proc = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var lines: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator
    var isAlive: Bool { proc.isRunning }

    init(system: String) throws {
        guard let exe = ClaudeCLI.executable() else {
            throw CoachError.api("没找到 claude 命令行。先在终端装好 Claude Code 并登录，或点「Key」填 API Key。")
        }
        // Run from an empty temp dir so no project CLAUDE.md / AGENTS.md gets loaded.
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("wechat-coach-cli")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let sysFile = workDir.appendingPathComponent("system.md")
        try system.write(to: sysFile, atomically: true, encoding: .utf8)

        proc.executableURL = URL(fileURLWithPath: exe)
        proc.currentDirectoryURL = workDir
        proc.arguments = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json",
            "--include-partial-messages", "--verbose",
            "--system-prompt-file", sysFile.path,
            "--tools", "", "--model", "opus", "--effort", Settings.effort,
            "--no-session-persistence", "--setting-sources", "", "--strict-mcp-config",
            "--disable-slash-commands",
        ]
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        lines = stdoutPipe.fileHandleForReading.bytes.lines.makeAsyncIterator()
        try proc.run()
    }

    func send(_ content: [[String: Any]], onText: @escaping @MainActor (String) -> Void) async throws {
        guard proc.isRunning else { throw CoachError.api("claude 命令行已退出，请重新点「分析」") }
        let msg: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        var data = try JSONSerialization.data(withJSONObject: msg)
        data.append(0x0A)
        stdinPipe.fileHandleForWriting.write(data)

        var it = lines  // iterate a local copy (actor-isolated stored iterators can't be advanced in place)
        defer { lines = it }
        while let line = try await it.next() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            if type == "stream_event", let ev = obj["event"] as? [String: Any],
               ev["type"] as? String == "content_block_delta",
               let delta = ev["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String {
                onText(text)
            } else if type == "result" {
                if obj["stop_reason"] as? String == "refusal" { throw CoachError.refusal }
                if obj["is_error"] as? Bool == true {
                    throw CoachError.api((obj["result"] as? String) ?? "claude 命令行报错")
                }
                return  // turn finished; the process stays up for the next follow-up
            }
        }
        let err = String(data: stderrPipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
        throw CoachError.api("claude 命令行意外退出：\(err.prefix(300))")
    }

    func close() {
        try? stdinPipe.fileHandleForWriting.close()
        if proc.isRunning { proc.terminate() }
    }
}

// MARK: - Reply parsing ("▶ 稳｜text" lines become copy buttons)

struct Reply: Equatable {
    let label: String
    let text: String

    /// Only complete lines are parsed, so half-streamed replies never show up as buttons.
    static func parse(_ s: String, includeLastLine: Bool) -> [Reply] {
        var lines = s.components(separatedBy: "\n")
        if !includeLastLine { lines.removeLast() }
        return lines.compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("▶") else { return nil }
            var body = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            var label = "推荐"
            for sep in ["｜", "|"] {
                if let r = body.range(of: sep), body.distance(from: body.startIndex, to: r.lowerBound) <= 6 {
                    label = String(body[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                    body = String(body[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                    break
                }
            }
            body = body.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”「」'"))
            return body.isEmpty ? nil : Reply(label: label.isEmpty ? "推荐" : label, text: body)
        }
    }
}

// MARK: - Floating panel UI

@MainActor
final class Coach: NSObject, NSWindowDelegate, NSApplicationDelegate {
    static let shared = Coach()

    private var panel: NSPanel!
    private let contactPopup = NSPopUpButton()
    private let sourceLabel = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "⌥⌘G 呼出面板，选好聊天后点「分析」")
    private let noteField = NSTextField()
    private let autoBox = NSButton(checkboxWithTitle: "她回了自动分析", target: nil, action: nil)
    private let repliesStack = NSStackView()
    private let output = NSTextView()
    private let askField = NSTextField()
    private var statusItem: NSStatusItem!

    private let systemPrompt = Claude.loadSystemPrompt()
    private var running = false
    private var conversation: CoachConversation?
    private var spare: CLIConversation?  // pre-started CLI so the next analysis skips process startup
    private var transcript = ""   // everything shown in the output view
    private var currentText = ""  // the coach's latest reply (reply buttons read this)
    private var shownReplies: [Reply] = []
    private var sessions: [WeFlowSession] = []
    private var autoTimer: Timer?
    private var lastAnalyzedId = 0
    private var pendingId = 0
    private var pendingSince = Date.distantPast

    private var selectedSession: WeFlowSession? {
        guard let u = contactPopup.selectedItem?.representedObject as? String else { return nil }
        return sessions.first { $0.username == u }
    }
    private var noteKey: String { selectedSession?.username ?? "_screenshot" }

    func start() {
        buildPanel()
        buildStatusItem()
        registerHotKey()
        panel.orderFrontRegardless()
        if KeyStore.load() == nil && ClaudeCLI.executable() == nil {
            setStatus("没找到 claude 命令行，也没有 API Key：二选一配置好再用")
        }
        prewarm()
        Task { await refreshSessions(detect: true) }
        if UserDefaults.standard.bool(forKey: "auto") {
            autoBox.state = .on
            toggleAuto()
        }
    }

    // MARK: layout

    private func buildPanel() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 420, height: 680)
        let frame = NSRect(x: screen.maxX - size.width - 16, y: screen.maxY - size.height - 16,
                           width: size.width, height: size.height)
        panel = NSPanel(contentRect: frame,
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.title = "狗头军师 · 微信恋爱教练"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 340, height: 420)
        panel.delegate = self

        // Row 1: who
        contactPopup.target = self
        contactPopup.action = #selector(contactChanged)
        contactPopup.addItem(withTitle: "（读取聊天列表中…）")
        contactPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let refreshBtn = NSButton(title: "↻", target: self, action: #selector(refreshClicked))
        refreshBtn.toolTip = "重新读取会话列表，并识别微信里当前打开的聊天"
        refreshBtn.bezelStyle = .rounded
        sourceLabel.textColor = .tertiaryLabelColor
        sourceLabel.font = .systemFont(ofSize: 11)
        let whoRow = NSStackView(views: [contactPopup, refreshBtn, sourceLabel])
        whoRow.spacing = 6

        // Row 2: per-contact background
        noteField.placeholderString = "关于 TA 的背景（按人保存）：怎么认识、到哪一步、你想要什么"
        noteField.target = self
        noteField.action = #selector(noteChanged)

        // Row 3: actions
        let analyzeBtn = NSButton(title: "分析", target: self, action: #selector(analyzeClicked))
        analyzeBtn.bezelStyle = .rounded
        analyzeBtn.keyEquivalent = ""
        autoBox.target = self
        autoBox.action = #selector(toggleAuto)
        autoBox.toolTip = "对方发来新消息并停顿几秒后自动分析（需要 WeFlow；每次分析都会消耗额度）"
        let keyBtn = NSButton(title: "Key", target: self, action: #selector(askKey))
        let actions = NSStackView(views: [analyzeBtn, autoBox, NSView(), keyBtn])
        actions.spacing = 8

        status.lineBreakMode = .byTruncatingTail
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)

        // Reply buttons
        repliesStack.orientation = .vertical
        repliesStack.alignment = .leading
        repliesStack.spacing = 6
        repliesStack.isHidden = true

        // Analysis text
        output.isEditable = false
        output.isSelectable = true
        output.font = .systemFont(ofSize: 13)
        output.textContainerInset = NSSize(width: 6, height: 8)
        output.isVerticallyResizable = true
        output.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = output
        scroll.borderType = .bezelBorder

        // Quick follow-ups
        let chips = ["更幽默", "更自然像我", "更直接", "TA 什么意思", "要不要约", "先别回？"].map { title -> NSButton in
            let b = NSButton(title: title, target: self, action: #selector(chipClicked(_:)))
            b.bezelStyle = .inline
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            return b
        }
        let chipRow = NSStackView(views: chips)
        chipRow.spacing = 4

        askField.placeholderString = "问军师 / 补充情况（回车发送）"
        askField.target = self
        askField.action = #selector(askSubmitted)
        let newBtn = NSButton(title: "新对话", target: self, action: #selector(newConversation))
        newBtn.toolTip = "清空和军师的对话（每次分析也会自动开新对话）"
        let askRow = NSStackView(views: [askField, newBtn])
        askRow.spacing = 6
        askField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [whoRow, noteField, actions, status, repliesStack, scroll, chipRow, askRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(10, after: status)

        let content = NSView()
        content.addSubview(stack)
        panel.contentView = content
        var cons = [
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ]
        for v in [whoRow, noteField, actions, status, repliesStack, scroll, chipRow, askRow] as [NSView] {
            cons.append(v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20))
        }
        NSLayoutConstraint.activate(cons)
        // Long status / placeholder text must truncate instead of widening the panel past the screen edge.
        for v in [status, sourceLabel, noteField, askField, contactPopup] as [NSView] {
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "💬"
        let menu = NSMenu()
        menu.addItem(withTitle: "显示面板 (⌥⌘G)", action: #selector(showPanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: "分析选中的聊天", action: #selector(analyzeClicked), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { Coach.shared.summon() } }
            return noErr
        }, 1, &spec, nil, nil)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x5743_4348), id: 1)  // "WCCH"
        RegisterEventHotKey(UInt32(kVK_ANSI_G), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }

    // MARK: contacts

    /// Reloads the session list; with `detect`, selects the chat currently open in WeChat.
    private func refreshSessions(detect: Bool) async {
        do { try await WeFlow.prepare(); WeFlow.markReady(true) } catch {
            WeFlow.markReady(false)
            sourceLabel.stringValue = "截图模式"
            contactPopup.removeAllItems()
            contactPopup.addItem(withTitle: "（读不了本地聊天记录，用截图）")
            contactPopup.isEnabled = false
            loadNote()
            setStatus(((error as? LocalizedError)?.errorDescription ?? "") + " 现在先用截图模式。")
            return
        }
        do {
            let previous = selectedSession?.username
            sessions = try await WeFlow.sessions()
            sourceLabel.stringValue = "本地记录"
            contactPopup.isEnabled = true
            contactPopup.removeAllItems()
            for s in sessions.prefix(60) {
                let unread = s.unreadCount > 0 ? "  ·\(s.unreadCount) 未读" : ""
                contactPopup.addItem(withTitle: s.displayName + unread)
                contactPopup.lastItem?.representedObject = s.username
            }
            var target = previous
            if detect, let open = await WeChatCapture.openChat(in: sessions) {
                target = open.username
                if !sessions.prefix(60).contains(where: { $0.username == open.username }) {
                    contactPopup.insertItem(withTitle: open.displayName, at: 0)
                    contactPopup.item(at: 0)?.representedObject = open.username
                }
            }
            if let target, let i = contactPopup.itemArray.firstIndex(where: { $0.representedObject as? String == target }) {
                contactPopup.selectItem(at: i)
            } else {
                contactPopup.selectItem(at: 0)
            }
            loadNote()
            if detect, !running { setStatus("当前：\(selectedSession?.displayName ?? "")，点「分析」开始") }
        } catch {
            show(error)
        }
    }

    private func loadNote() { noteField.stringValue = Settings.note(for: noteKey) }

    @objc private func contactChanged() {
        loadNote()
        lastAnalyzedId = 0
        pendingId = 0
        setStatus("已切换到 \(selectedSession?.displayName ?? "")，点「分析」开始")
    }

    @objc private func refreshClicked() { Task { await refreshSessions(detect: true) } }

    // MARK: actions

    @objc private func showPanel() { panel.orderFrontRegardless() }
    @objc private func analyzeClicked() { analyze(detect: false) }
    /// Hotkey: bring the panel up and select the chat open in WeChat. Never starts an analysis by itself.
    func summon() {
        panel.orderFrontRegardless()
        guard !running else { return }
        Task { await refreshSessions(detect: true) }
    }
    @objc private func noteChanged() {
        Settings.setNote(noteField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), for: noteKey)
    }

    @objc private func askKey() {
        let alert = NSAlert()
        alert.messageText = "Anthropic API Key（可选，不填就用 claude 命令行）"
        alert.informativeText = "保存在本机钥匙串（Keychain）里，只发给 api.anthropic.com。"
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { KeyStore.save(key); setStatus("Key 已保存，点「分析」开始") }
        }
    }

    @objc private func copyReply(_ sender: NSButton) {
        guard sender.tag < shownReplies.count else { return }
        let text = shownReplies[sender.tag].text
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        // Jump back to WeChat so the user only has to press ⌘V and Enter.
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.xinWeChat").first?.activate()
        setStatus("已复制，到微信 ⌘V 发送：\(text)")
    }

    @objc private func chipClicked(_ sender: NSButton) {
        let prompts = [
            "更幽默": "再给 3 个更幽默、更有梗的回法。",
            "更自然像我": "这些太像教练写的了。照着我在记录里平时的说话习惯（长度、语气词、表情）重写 3 个版本。",
            "更直接": "给更直接、推进感更强的版本，但别油腻。",
            "TA 什么意思": "TA 最后这几条到底什么意思？兴趣怎么样？",
            "要不要约": "现在适合约 TA 吗？要约的话具体怎么约，给能直接发的话。",
            "先别回？": "我是不是应该先别回 / 晚点回？给我时机建议。",
        ]
        ask(prompts[sender.title] ?? sender.title)
    }

    @objc private func toggleAuto() {
        autoTimer?.invalidate()
        autoTimer = nil
        UserDefaults.standard.set(autoBox.state == .on, forKey: "auto")
        guard autoBox.state == .on else { setStatus("自动分析已关闭"); return }
        guard WeFlow.isConfigured else {
            setStatus("自动分析需要能读取本地聊天记录（现在是截图模式）")
            return
        }
        pendingId = 0
        setStatus("自动分析：\(selectedSession?.displayName ?? "当前对象")发来新消息后自动分析")
        autoTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { Coach.shared.autoTick() }
        }
    }

    /// Polls the newest message; analyzes once TA has sent something new and then paused for a few seconds
    /// (people often send several bubbles in a row).
    private func autoTick() {
        guard !running, let s = selectedSession else { return }
        Task {
            guard let last = try? await WeFlow.messages(talker: s.username, limit: 1).last else { return }
            if lastAnalyzedId == 0 { lastAnalyzedId = last.localId; return }  // don't spend a call on old history
            guard !last.isSend, last.localId != lastAnalyzedId else { pendingId = 0; return }
            if last.localId != pendingId { pendingId = last.localId; pendingSince = Date(); return }
            guard Date().timeIntervalSince(pendingSince) >= 5, !running else { return }
            analyze(detect: false)
        }
    }

    // MARK: analysis

    func analyze(detect: Bool) {
        panel.orderFrontRegardless()
        guard !running else { return }
        running = true
        Task {
            do {
                let content: [[String: Any]]
                if WeFlow.isConfigured {
                    setStatus("读取聊天记录…")
                    if detect || sessions.isEmpty { await refreshSessions(detect: detect) }
                    guard let s = selectedSession else { throw CoachError.noContact }
                    noteChanged()
                    let msgs = try await WeFlow.messages(talker: s.username, limit: Settings.historyCount)
                    guard !msgs.isEmpty else { throw CoachError.weflow("和 \(s.displayName) 还没有聊天记录") }
                    lastAnalyzedId = msgs.last!.localId
                    pendingId = 0
                    content = Claude.textContent(WeFlow.transcript(msgs, name: s.displayName, note: noteField.stringValue))
                    setStatus("分析和 \(s.displayName) 的最近 \(msgs.count) 条消息…")
                } else {
                    setStatus("截取微信窗口…")
                    let img = try await WeChatCapture.capture()
                    guard let jpeg = WeChatCapture.jpegData(img) else { throw CoachError.api("截图编码失败") }
                    noteChanged()
                    content = Claude.screenshotContent(jpeg: jpeg, note: noteField.stringValue)
                    setStatus("分析截图中（截图模式只看当前一屏）…")
                }
                // Each analysis starts a fresh conversation with the coach.
                conversation?.close()
                conversation = try takeConversation()
                transcript = ""
                currentText = ""
                output.string = ""
                updateReplies(final: false)
                let started = Date()
                try await conversation!.send(content) { Coach.shared.append($0) }
                updateReplies(final: true)
                setStatus(String(format: "完成（%.0f 秒）· 点上面的回复即复制，或继续追问", Date().timeIntervalSince(started)))
            } catch {
                show(error)
            }
            running = false
        }
    }

    /// Uses the pre-started CLI process when there is one, then starts the next spare in the background.
    private func takeConversation() throws -> CoachConversation {
        if let key = KeyStore.load() { return APIConversation(key: key, system: systemPrompt) }
        let convo: CLIConversation
        if let s = spare, s.isAlive { convo = s } else { convo = try CLIConversation(system: systemPrompt) }
        spare = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { Coach.shared.prewarm() } }
        return convo
    }

    private func prewarm() {
        guard KeyStore.load() == nil, spare?.isAlive != true else { return }
        spare = try? CLIConversation(system: systemPrompt)
    }

    @objc private func newConversation() {
        guard !running else { return }
        conversation?.close()
        conversation = nil
        transcript = ""
        currentText = ""
        output.string = ""
        updateReplies(final: true)
        setStatus("已清空。点「分析」看聊天，或直接在下方提问")
    }

    @objc private func askSubmitted() {
        let question = askField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        askField.stringValue = ""
        ask(question)
    }

    private func ask(_ question: String) {
        guard !running else { setStatus("军师还在说，稍等…"); return }
        running = true
        Task {
            do {
                let fresh = conversation == nil
                if fresh {
                    // No chat loaded yet: plain Q&A (knowledge questions, situations described in words).
                    conversation = try takeConversation()
                    transcript = ""
                }
                transcript += (transcript.isEmpty ? "" : "\n\n") + "🙋 你：\(question)\n\n"
                currentText = ""
                output.string = transcript
                output.scrollToEndOfDocument(nil)
                setStatus("军师思考中…")
                let started = Date()
                var text = question
                let note = noteField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if fresh && !note.isEmpty { text += "\n背景补充：\(note)" }
                try await conversation!.send(Claude.textContent(text)) { Coach.shared.append($0) }
                updateReplies(final: true)
                setStatus(String(format: "完成（%.0f 秒）", Date().timeIntervalSince(started)))
            } catch {
                show(error)
            }
            running = false
        }
    }

    fileprivate func append(_ text: String) {
        currentText += text
        transcript += text
        output.string = transcript
        output.scrollToEndOfDocument(nil)
        if text.contains("\n") { updateReplies(final: false) }
    }

    /// Rebuilds the copy buttons from the latest coach reply. Keeps the previous buttons when a follow-up
    /// answer contains no new replies.
    private func updateReplies(final: Bool) {
        let replies = Reply.parse(currentText, includeLastLine: final)
        if replies.isEmpty && !currentText.isEmpty && !shownReplies.isEmpty { return }
        guard replies != shownReplies else { return }
        shownReplies = replies
        repliesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        repliesStack.isHidden = replies.isEmpty
        for (i, r) in replies.enumerated() {
            let btn = NSButton(title: r.label, target: self, action: #selector(copyReply(_:)))
            btn.tag = i
            btn.bezelStyle = .rounded
            btn.controlSize = .small
            btn.toolTip = "复制并切回微信"
            btn.setContentHuggingPriority(.required, for: .horizontal)
            btn.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            let text = NSTextField(wrappingLabelWithString: r.text)
            text.font = .systemFont(ofSize: 14)
            text.isSelectable = true
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [btn, text])
            row.alignment = .firstBaseline
            row.spacing = 8
            repliesStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: repliesStack.widthAnchor).isActive = true
        }
    }

    private func show(_ error: Error) {
        let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if case CoachError.refusal = error {
            // Drop only the partial reply that was declined; keep the rest of the conversation on screen.
            if transcript.hasSuffix(currentText) { transcript.removeLast(currentText.count) }
            currentText = ""
            output.string = transcript
        }
        if (error as NSError).domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" {
            setStatus("需要屏幕录制权限：系统设置 → 隐私与安全性 → 屏幕与系统音频录制，勾选 WeChatCoach 后重启它")
        } else {
            setStatus(msg)
        }
    }

    private func setStatus(_ s: String) {
        status.stringValue = s
        status.toolTip = s
    }

    // `open WeChatCoach.app` again while running → bring the panel back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.orderFrontRegardless()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        conversation?.close()
        spare?.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        panel.orderOut(nil)  // keep running in the menu bar
        return false
    }
}

// MARK: - Entry

let args = CommandLine.arguments

// Diagnostics without UI: WeChatCoach --source-check   (counts and timings only, no chat content)
if args.count >= 2, args[1] == "--source-check" {
    Task { @MainActor in
        do {
            var t = Date()
            try await WeFlow.prepare()
            print(String(format: "[source] key ready (%.2fs)", Date().timeIntervalSince(t)))
            t = Date()
            let s = try await WeFlow.sessions()
            print(String(format: "[source] %d private sessions (%.2fs)", s.count, Date().timeIntervalSince(t)))
            if let first = s.first {
                t = Date()
                let m = try await WeFlow.messages(talker: first.username, limit: Settings.historyCount)
                let types = Dictionary(grouping: m, by: \.type).mapValues(\.count)
                let empty = m.filter { $0.type == 1 && $0.content.isEmpty }.count
                print(String(format: "[source] most recent chat: %d msgs (%.2fs), sent=%d received=%d, empty text=%d, types=%@",
                             m.count, Date().timeIntervalSince(t), m.filter(\.isSend).count, m.filter { !$0.isSend }.count,
                             empty, types.description))
                let toMe = m.filter { $0.sender == first.username }.count
                let mine = m.filter { $0.isSend }.count
                let other = m.filter { $0.sender != first.username && !$0.isSend }.count
                print("[source] sender check: from-them=\(toMe) mine=\(mine) unknown=\(other) (unknown should be 0)")
                let tr = WeFlow.transcript(m, name: "X", note: "")
                let lines = tr.split(separator: "\n")
                let leaks = lines.filter { $0.contains("<") || $0.contains("&lt;") || $0.contains("CDATA") }.count
                func n(_ k: String) -> Int { lines.filter { $0.contains(k) }.count }
                print("[source] transcript: \(lines.count) lines, \(tr.count) chars, xml-leak lines=\(leaks), 引用=\(n("（引用：")) 链接=\(n("[链接]")) 分享=\(n("[分享]")) 其他=\(n("[其他消息]"))")
                if let last = m.last {
                    print("[source] newest message is \(Int(Date().timeIntervalSince1970) - last.createTime)s old, from \(last.isSend ? "me" : "them")")
                }
                t = Date()
                _ = try await WeFlow.messages(talker: first.username, limit: 5)
                print(String(format: "[source] cached re-read: %.2fs", Date().timeIntervalSince(t)))
            }
            exit(0)
        } catch {
            print("[source] \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            exit(1)
        }
    }
    dispatchMain()
}

// Full export of one chat: WeChatCoach --export <talker wxid> <out.jsonl>   (prints counts only)
if args.count >= 4, args[1] == "--export" {
    do {
        let t0 = Date()
        let msgs = try WeChatDB.messages(talker: args[2], limit: 10_000_000)
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(identifier: "Asia/Shanghai")
        var out = ""
        var kept = 0
        for m in msgs {
            guard let text = WeFlow.describe(m) else { continue }
            let row: [String: Any] = ["ts": m.createTime, "time": iso.string(from: Date(timeIntervalSince1970: TimeInterval(m.createTime))),
                                      "from": m.isSend ? "me" : "them", "type": m.type, "text": text]
            let d = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes])
            out += String(decoding: d, as: UTF8.self) + "\n"
            kept += 1
        }
        try out.write(toFile: args[3], atomically: true, encoding: .utf8)
        let mine = msgs.filter(\.isSend).count
        let first = msgs.first.map { iso.string(from: Date(timeIntervalSince1970: TimeInterval($0.createTime))) } ?? "-"
        let last = msgs.last.map { iso.string(from: Date(timeIntervalSince1970: TimeInterval($0.createTime))) } ?? "-"
        print(String(format: "[export] %d msgs read, %d written (me=%d them=%d), %@ → %@, %.1fs",
                     msgs.count, kept, mine, msgs.count - mine, first, last, Date().timeIntervalSince(t0)))
        exit(0)
    } catch {
        print("[export] \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        exit(1)
    }
}

// Analyze one contact end-to-end without the panel: WeChatCoach --analyze <keyword>
if args.count >= 3, args[1] == "--analyze" {
    Task { @MainActor in
        do {
            guard let x = try await WeFlow.sessions().first(where: { $0.displayName.contains(args[2]) }) else {
                print("[analyze] 没找到包含「\(args[2])」的聊天"); exit(1)
            }
            if args.count >= 4 { Settings.setNote(args[3], for: x.username) }  // same per-contact note the panel shows
            let m = try await WeFlow.messages(talker: x.username, limit: Settings.historyCount)
            let t0 = Date()
            let convo = try CLIConversation(system: Claude.loadSystemPrompt())
            var reply = ""
            try await convo.send(Claude.textContent(WeFlow.transcript(m, name: x.displayName, note: Settings.note(for: x.username)))) {
                reply += $0
            }
            print(reply)
            print(String(format: "\n[analyze] %@，%d 条消息，%.0f 秒", x.displayName, m.count, Date().timeIntervalSince(t0)))
            convo.close()
            exit(0)
        } catch {
            print("[analyze] \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            exit(1)
        }
    }
    dispatchMain()
}

// Find a contact by name: WeChatCoach --find <keyword>   (rank, name, counts only)
if args.count >= 3, args[1] == "--find" {
    Task { @MainActor in
        do {
            let s = try await WeFlow.sessions()
            for (i, x) in s.enumerated() where x.displayName.contains(args[2]) {
                let m = try await WeFlow.messages(talker: x.username, limit: Settings.historyCount)
                let age = m.last.map { (Int(Date().timeIntervalSince1970) - $0.createTime) / 60 } ?? -1
                let fp = WeChatDB.md5Hex(m.map { "\($0.localId)|\($0.content)" }.joined(separator: "\n")).prefix(10)
                let ids = m.map(\.localId)
                print("[find] #\(i + 1) \(x.displayName) user=\(x.username.prefix(6))… table=Msg_\(WeChatDB.md5Hex(x.username).prefix(8))…: \(m.count) msgs, newest \(age) min ago, mine=\(m.filter(\.isSend).count), localId \(ids.min() ?? 0)-\(ids.max() ?? 0), fingerprint=\(fp)")
            }
            exit(0)
        } catch {
            print("[find] \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            exit(1)
        }
    }
    dispatchMain()
}

// Schema-only report of the local WeChat databases: WeChatCoach --db-check   (no message content)
if args.count >= 2, args[1] == "--db-check" {
    do { print(try WeChatDB.diagnose()); exit(0) } catch {
        print("[db] \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        exit(1)
    }
}

// Self-test with a text transcript: WeChatCoach --selftest-text <transcript.txt> [follow-up]
if args.count >= 3, args[1] == "--selftest-text" {
    let text = try String(contentsOf: URL(fileURLWithPath: args[2]), encoding: .utf8)
    let followUp = args.count >= 4 ? args[3] : "更自然像我一点"
    Task { @MainActor in
        do {
            var reply = ""
            let printChunk: @MainActor (String) -> Void = { reply += $0; print($0, terminator: ""); fflush(stdout) }
            let t0 = Date()
            let convo = try CLIConversation(system: Claude.loadSystemPrompt())
            try await convo.send(Claude.textContent(text), onText: printChunk)
            print(String(format: "\n\n[turn 1: %.1fs]", Date().timeIntervalSince(t0)))
            for r in Reply.parse(reply, includeLastLine: true) { print("[button] \(r.label) → \(r.text)") }
            reply = ""
            print("\n🙋 你：\(followUp)\n")
            try await convo.send(Claude.textContent(followUp), onText: printChunk)
            for r in Reply.parse(reply, includeLastLine: true) { print("[button] \(r.label) → \(r.text)") }
            convo.close()
            print("\n[selftest ok]")
            exit(0)
        } catch {
            print("\n[selftest failed] \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            exit(1)
        }
    }
    dispatchMain()  // keep the main queue free for @MainActor callbacks
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
MainActor.assumeIsolated { app.delegate = Coach.shared; Coach.shared.start() }
app.run()
