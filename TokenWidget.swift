import AppKit
import SwiftUI
import CryptoKit
import Network
import Combine
import ServiceManagement
import Carbon.HIToolbox

// MARK: - 定价(美元 / 每百万 token,用于「今日费用」)

struct Pricing {
    let input: Double
    let output: Double

    static func of(_ model: String) -> Pricing {
        let m = model.lowercased()
        if m.contains("fable") || m.contains("mythos") { return Pricing(input: 10, output: 50) }
        if m.contains("opus")   { return Pricing(input: 5,  output: 25) }
        if m.contains("haiku")  { return Pricing(input: 1,  output: 5)  }
        if m.contains("sonnet") { return Pricing(input: 3,  output: 15) }
        return Pricing(input: 5, output: 25)
    }
}

// MARK: - 用量事件(本地 JSONL,驱动「今日费用」和活动图)

struct UsageEvent {
    let date: Date
    let model: String
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite5m: Int
    let cacheWrite1h: Int

    var totalTokens: Int { input + output + cacheRead + cacheWrite5m + cacheWrite1h }

    var cost: Double {
        let p = Pricing.of(model)
        return (Double(input) * p.input
              + Double(output) * p.output
              + Double(cacheRead) * p.input * 0.1
              + Double(cacheWrite5m) * p.input * 1.25
              + Double(cacheWrite1h) * p.input * 2.0) / 1_000_000
    }
}

// MARK: - 工具

private let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoPlain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()
func parseDate(_ s: String) -> Date? { isoFrac.date(from: s) ?? isoPlain.date(from: s) }

let weekdayHM: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = "EEE HH:mm"
    return f
}()

let weekdayShort: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = "EEEEE" // 一 二 三 … 日
    return f
}()

func fmtTokens(_ n: Int) -> String {
    let d = Double(n)
    switch d {
    case 1_000_000_000...: return String(format: "%.2fB", d / 1e9)
    case 1_000_000...:     return String(format: "%.2fM", d / 1e6)
    case 1_000...:         return String(format: "%.1fK", d / 1e3)
    default:               return "\(n)"
    }
}

func fmtMoney(_ v: Double) -> String {
    if v <= 0 { return "$0.00" }
    if v < 0.01 { return "<$0.01" }
    if v < 100 { return String(format: "$%.2f", v) }
    return String(format: "$%.0f", v)
}

func fmtRemain(_ t: TimeInterval) -> String {
    let m = max(0, Int(t) / 60)
    if m >= 60 { return "\(m / 60) 小时 \(m % 60) 分" }
    return "\(m) 分钟"
}

// MARK: - 本地数据引擎:增量读取 ~/.claude/projects/**/*.jsonl

final class UsageStore: ObservableObject {
    @Published var events: [UsageEvent] = []
    @Published var lastRefresh = Date()

    private let queue = DispatchQueue(label: "token-widget.scan", qos: .utility)
    private var offsets: [String: UInt64] = [:]      // 仅在 queue 上访问
    private var eventMap: [String: UsageEvent] = [:] // 仅在 queue 上访问
    private var timer: Timer?

    private let projectsDir = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    func start() {
        scanAndPublish()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.scanAndPublish()
        }
    }

    private func scanAndPublish() {
        queue.async { [weak self] in
            guard let self else { return }
            self.scan()
            let arr = Array(self.eventMap.values)
            DispatchQueue.main.async {
                self.events = arr
                self.lastRefresh = Date()
            }
        }
    }

    private func scan() {
        let now = Date()
        // 保留近 7 天数据(供历史统计),外加跨午夜缓冲
        let dayStart = Calendar.current.startOfDay(for: now)
        let cutoff = min(dayStart.addingTimeInterval(-6 * 86400), now.addingTimeInterval(-2 * 3600))

        eventMap = eventMap.filter { $0.value.date >= cutoff }

        guard let en = FileManager.default.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let url as URL in en {
            guard url.pathExtension == "jsonl" else { continue }
            guard let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let mtime = rv.contentModificationDate,
                  let size = rv.fileSize else { continue }

            let path = url.path
            if offsets[path] == nil && mtime < cutoff { continue }

            var offset = offsets[path] ?? 0
            if UInt64(size) < offset { offset = 0 }
            guard UInt64(size) > offset else { continue }

            guard let fh = FileHandle(forReadingAtPath: path) else { continue }
            defer { fh.closeFile() }
            fh.seek(toFileOffset: offset)
            let data = fh.readDataToEndOfFile()

            var usable = data
            if data.last != 0x0A { // 丢弃尾部未写完的半行
                if let lastNL = data.lastIndex(of: 0x0A) {
                    usable = data[data.startIndex...lastNL]
                } else {
                    continue
                }
            }
            offsets[path] = offset + UInt64(usable.count)
            parseLines(usable, cutoff: cutoff)
        }
    }

    private func parseLines(_ data: Data, cutoff: Date) {
        func num(_ k: String, _ d: [String: Any]) -> Int {
            (d[k] as? Int) ?? ((d[k] as? NSNumber)?.intValue ?? 0)
        }

        for line in data.split(separator: 0x0A) {
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any],
                  let ts = obj["timestamp"] as? String,
                  let date = parseDate(ts),
                  date >= cutoff else { continue }

            let model = msg["model"] as? String ?? "unknown"
            if model == "<synthetic>" { continue }

            let input = num("input_tokens", usage)
            let output = num("output_tokens", usage)
            let cacheRead = num("cache_read_input_tokens", usage)
            var w5 = 0, w1 = 0
            if let cc = usage["cache_creation"] as? [String: Any] {
                w5 = num("ephemeral_5m_input_tokens", cc)
                w1 = num("ephemeral_1h_input_tokens", cc)
            } else {
                w5 = num("cache_creation_input_tokens", usage)
            }
            if input + output + cacheRead + w5 + w1 == 0 { continue }

            let key = ((msg["id"] as? String) ?? UUID().uuidString) + ":" + ((obj["requestId"] as? String) ?? "")
            let ev = UsageEvent(date: date, model: model, input: input, output: output,
                                cacheRead: cacheRead, cacheWrite5m: w5, cacheWrite1h: w1)
            if let old = eventMap[key] {
                if ev.output >= old.output { eventMap[key] = ev }
            } else {
                eventMap[key] = ev
            }
        }
    }
}

// MARK: - 今日统计

struct Stats {
    var todayCost = 0.0
    var todayTokens = 0
    var todayRequests = 0
    var sparkline: [Double] = Array(repeating: 0, count: 60)
    var daily: [(day: Date, cost: Double)] = [] // 近 7 天每日费用
    var lastEvent: Date?

    static func compute(events: [UsageEvent], now: Date) -> Stats {
        var s = Stats()
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: now)
        let sparkStart = now.addingTimeInterval(-3600)
        var dayCost: [Date: Double] = [:]
        for e in events {
            if e.date >= dayStart {
                s.todayCost += e.cost
                s.todayTokens += e.totalTokens
                s.todayRequests += 1
            }
            if e.date >= sparkStart {
                let idx = Int(e.date.timeIntervalSince(sparkStart) / 60)
                if idx >= 0 && idx < 60 { s.sparkline[idx] += Double(e.totalTokens) }
            }
            dayCost[cal.startOfDay(for: e.date), default: 0] += e.cost
            if s.lastEvent == nil || e.date > s.lastEvent! { s.lastEvent = e.date }
        }
        s.daily = (0..<7).reversed().compactMap { i in
            guard let day = cal.date(byAdding: .day, value: -i, to: dayStart) else { return nil }
            return (day, dayCost[day] ?? 0)
        }
        return s
    }
}

// MARK: - 官方套餐用量(与 Claude 设置里 Usage 页同源)

struct LimitRow: Identifiable {
    let id: String
    let label: String
    let pct: Double
    let resetsAt: Date?
    let rank: Int
    let isSession: Bool
    let severity: String? // 服务端给的严重度: normal / warning / critical
}

final class LimitsStore: ObservableObject {
    @Published var rows: [LimitRow] = []
    @Published var errorText: String?
    @Published var lastOK: Date?
    @Published var needsAuth = false

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private var token: String?
    private var timer: Timer?
    private let fetchLock = NSLock()
    private var isFetching = false
    private var nextAllowedFetch = Date.distantPast // 限流退避 + 基础节流
    private var rateLimitStreak = 0

    func start() {
        fetch()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.fetch()
        }
    }

    /// force = 用户主动操作(菜单刷新/登录成功),忽略节流窗口
    func fetch(force: Bool = false) {
        guard force || Date() >= nextAllowedFetch else { return }
        fetchLock.lock()
        let busy = isFetching
        if !busy { isFetching = true }
        fetchLock.unlock()
        guard !busy else { return } // 上一次还没结束(例如钥匙串授权框还没点)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.performFetch(allowAuthRetry: true)
        }
    }

    private func done() {
        fetchLock.lock(); isFetching = false; fetchLock.unlock()
    }

    private func performFetch(allowAuthRetry: Bool) {
        guard let tok = token ?? Self.readToken() else {
            DispatchQueue.main.async {
                self.needsAuth = true
                self.errorText = nil
            }
            done()
            return
        }
        token = tok

        var req = URLRequest(url: Self.endpoint)
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 15

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self else { return }
            if let err {
                DebugLog.log("请求失败: \(err.localizedDescription)")
                self.publish(error: "网络连接失败")
                self.done()
                return
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                DebugLog.log("HTTP \(code): \(body.prefix(300))")
                self.token = nil
                // 先尝试刷新小组件自己的 OAuth 令牌,再重读其他来源
                if allowAuthRetry, let fresh = TokenFile.refreshSync() ?? Self.readToken(), fresh != tok {
                    self.token = fresh
                    self.performFetch(allowAuthRetry: false)
                    return
                }
                // 令牌无效或权限不足 → 显示登录入口
                DispatchQueue.main.async {
                    self.needsAuth = true
                    self.errorText = nil
                }
                self.done()
                return
            }
            if code == 429 {
                // 被限流:优先听服务器的 Retry-After,否则指数退避 5→10→20→30 分钟
                let ra = (resp as? HTTPURLResponse)?
                    .value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                DispatchQueue.main.async {
                    let delay = ra ?? min(300 * pow(2.0, Double(self.rateLimitStreak)), 1800)
                    self.rateLimitStreak += 1
                    self.nextAllowedFetch = Date().addingTimeInterval(delay)
                    DebugLog.log("HTTP 429 限流,\(Int(delay)) 秒后重试")
                    self.errorText = "接口限流,约 \(max(1, Int(delay / 60))) 分钟后自动重试"
                }
                self.done()
                return
            }
            guard code == 200, let data else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                DebugLog.log("HTTP \(code): \(body.prefix(300))")
                self.publish(error: "接口返回 \(code)")
                self.done()
                return
            }
            DebugLog.log("HTTP 200: \(String(data: data, encoding: .utf8)?.prefix(1200) ?? "")")
            self.parse(data)
            self.done()
        }.resume()
    }

    private func parse(_ data: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            publish(error: "无法解析用量数据")
            return
        }
        var rows: [LimitRow] = []

        // 新版结构:limits 数组(含分模型限额和严重度),与设置页 Usage 一一对应
        if let limits = obj["limits"] as? [[String: Any]] {
            for (i, d) in limits.enumerated() {
                guard let pct = (d["percent"] as? NSNumber)?.doubleValue else { continue }
                let kind = d["kind"] as? String ?? "limit\(i)"
                let label: String
                switch kind {
                case "session": label = "当前会话"
                case "weekly_all": label = "本周 · 全部模型"
                case "weekly_scoped":
                    let name = (((d["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String)
                    label = "本周 · \(name ?? "高级模型")"
                default: label = kind
                }
                rows.append(LimitRow(id: "\(kind)-\(i)", label: label, pct: pct,
                                     resetsAt: (d["resets_at"] as? String).flatMap(parseDate),
                                     rank: i,
                                     isSession: kind == "session",
                                     severity: d["severity"] as? String))
            }
        }

        // 旧版结构兜底:five_hour / seven_day 顶层字段
        if rows.isEmpty {
            var raw: [(key: String, u: Double, resets: Date?)] = []
            for (key, val) in obj {
                guard let d = val as? [String: Any],
                      let u = (d["utilization"] as? NSNumber)?.doubleValue else { continue }
                raw.append((key, u, (d["resets_at"] as? String).flatMap(parseDate)))
            }
            // 兼容 0-1 小数与 0-100 百分数两种刻度
            let scale: Double = (raw.map(\.u).max() ?? 0) <= 1.0 ? 100 : 1
            rows = raw
                .map { LimitRow(id: $0.key, label: Self.label($0.key), pct: $0.u * scale,
                                resetsAt: $0.resets, rank: Self.rank($0.key),
                                isSession: $0.key == "five_hour", severity: nil) }
                .sorted { ($0.rank, $0.id) < ($1.rank, $1.id) }
        }

        guard !rows.isEmpty else {
            DebugLog.log("解析不到用量字段,顶层 keys: \(obj.keys.sorted())")
            publish(error: "接口无用量字段")
            return
        }
        DebugLog.log("解析成功 \(rows.count) 条: \(rows.map { "\($0.label)=\(Int($0.pct))%" }.joined(separator: ", "))")
        let final = Array(rows.prefix(4))

        DispatchQueue.main.async {
            self.rows = final
            self.errorText = nil
            self.needsAuth = false
            self.lastOK = Date()
            self.rateLimitStreak = 0
            self.nextAllowedFetch = Date().addingTimeInterval(110) // 成功后基础节流 ~2 分钟
        }
    }

    private func publish(error: String) {
        DispatchQueue.main.async { self.errorText = error } // 保留上次数据
    }

    private static func rank(_ k: String) -> Int {
        if k == "five_hour" { return 0 }
        if k == "seven_day" { return 1 }
        if k.contains("fable") || k.contains("mythos") || k.contains("opus") { return 2 }
        if k.contains("seven_day") { return 3 }
        return 4
    }

    private static func label(_ k: String) -> String {
        if k == "five_hour" { return "当前会话" }
        if k == "seven_day" { return "本周 · 全部模型" }
        if k.contains("fable") || k.contains("mythos") { return "本周 · Fable" }
        if k.contains("opus") { return "本周 · Fable" } // 该字段历史上是 Opus 档,现对应 Fable
        if k.contains("sonnet") { return "本周 · Sonnet" }
        if k.contains("haiku") { return "本周 · Haiku" }
        if k.contains("extra") { return "额外用量" }
        return k
    }

    // 凭证只在本机读取:依次尝试已知的文件位置和钥匙串条目名(CLI 版 / 桌面版不同)
    private static func readToken() -> String? {
        // 0. 小组件自己的 OAuth 令牌(小组件内登录生成,自动刷新)
        if let t = TokenFile.currentAccess() {
            DebugLog.log("凭证来源: widget-token.json")
            return t
        }

        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let fileCandidates = [
            home.appendingPathComponent(".claude/widget-token"), // 手动兜底(见 README)
            home.appendingPathComponent(".claude/.credentials.json"),
            home.appendingPathComponent(".claude/credentials.json"),
            home.appendingPathComponent(".config/claude/.credentials.json"),
            home.appendingPathComponent("Library/Application Support/Claude Code/.credentials.json"),
        ]
        for url in fileCandidates {
            guard fm.fileExists(atPath: url.path) else { continue }
            if let data = try? Data(contentsOf: url), let t = extractToken(data) {
                DebugLog.log("凭证来源: \(url.path.replacingOccurrences(of: home.path, with: "~"))")
                return t
            }
            DebugLog.log("文件存在但解析不到 token: \(url.lastPathComponent)")
        }

        let services = [
            "Claude Code-credentials",
            "Claude Code",
            "Claude Code Desktop-credentials",
            "claude-code-credentials",
            "com.anthropic.claude-code",
        ]
        for s in services {
            if let t = keychainRead(service: s) {
                DebugLog.log("凭证来源: 钥匙串「\(s)」")
                return t
            }
        }
        DebugLog.log("所有已知位置均未找到凭证(已试 \(fileCandidates.count) 个文件 + \(services.count) 个钥匙串条目)")

        // 诊断:列出 Application Support 下相关目录(仅名称)
        let asDir = home.appendingPathComponent("Library/Application Support")
        if let names = try? fm.contentsOfDirectory(atPath: asDir.path) {
            let hits = names.filter { $0.lowercased().contains("claude") || $0.lowercased().contains("anthropic") }
            DebugLog.log("Application Support 相关目录: \(hits)")
        }
        if let names = try? fm.contentsOfDirectory(atPath: home.appendingPathComponent(".claude").path) {
            DebugLog.log("~/.claude 目录内容: \(names)")
        }
        return nil
    }

    private static func keychainRead(service: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return extractToken(pipe.fileHandleForReading.readDataToEndOfFile())
    }

    private static func extractToken(_ data: Data) -> String? {
        func fromObj(_ o: [String: Any]) -> String? {
            if let t = (o["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String { return t }
            if let t = o["accessToken"] as? String { return t }
            return nil
        }
        if let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let t = fromObj(o) { return t }
        if let s = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) {
            if let d = s.data(using: .utf8),
               let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
               let t = fromObj(o) { return t }
            if s.hasPrefix("sk-ant-") { return s } // 纯 token 字符串
        }
        return nil
    }
}

// MARK: - 诊断日志(~/Library/Logs/TokenWidget.log,不记录任何凭证)

enum DebugLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/TokenWidget.log")
    private static let df: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    static func log(_ s: String) {
        let line = "[\(df.string(from: Date()))] \(s)\n"
        guard let d = line.data(using: .utf8) else { return }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 200_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(d); h.closeFile()
        } else {
            try? d.write(to: url)
        }
    }
}

// MARK: - OAuth 登录(与 Claude Code 同一公开客户端,PKCE 流程,令牌仅存本机)

extension Data {
    var b64url: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum OAuth {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e" // Claude Code 公开 client_id
    static let redirect = "https://console.anthropic.com/oauth/code/callback"
    static let scopes = "user:profile user:inference" // 只申请必需的最小权限
    static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!

    static func randomB64URL(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).b64url
    }
}

struct WidgetToken: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Double? // epoch 秒
}

enum TokenFile {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/widget-token.json")

    static func load() -> WidgetToken? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetToken.self, from: d)
    }

    static func save(_ t: WidgetToken) {
        guard let d = try? JSONEncoder().encode(t) else { return }
        try? d.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// 取当前可用的 accessToken,快过期则先刷新(在后台线程调用)
    static func currentAccess() -> String? {
        guard let t = load() else { return nil }
        if let exp = t.expiresAt, exp - 300 < Date().timeIntervalSince1970, t.refreshToken != nil {
            return refreshSync() ?? t.accessToken
        }
        return t.accessToken
    }

    static func refreshSync() -> String? {
        guard var t = load(), let rt = t.refreshToken else { return nil }
        var req = URLRequest(url: OAuth.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": rt,
            "client_id": OAuth.clientID,
        ])
        req.timeoutInterval = 15
        let sem = DispatchSemaphore(value: 0)
        var result: String?
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200, let data,
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let at = o["access_token"] as? String else {
                DebugLog.log("刷新令牌失败 HTTP \(code)")
                return
            }
            t.accessToken = at
            if let nrt = o["refresh_token"] as? String { t.refreshToken = nrt }
            if let ei = (o["expires_in"] as? NSNumber)?.doubleValue {
                t.expiresAt = Date().timeIntervalSince1970 + ei
            }
            save(t)
            DebugLog.log("OAuth 令牌已自动刷新")
            result = at
        }.resume()
        sem.wait()
        return result
    }
}

/// 本地回调服务器:接收浏览器授权后的重定向,自动拿到授权码
final class CallbackServer {
    private var listener: NWListener?
    var onCode: (String, String) -> Void = { _, _ in }

    static func portFree(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return r == 0
    }

    func start(port: UInt16) -> Bool {
        stop()
        guard Self.portFree(port),
              let nwPort = NWEndpoint.Port(rawValue: port),
              let l = try? NWListener(using: .tcp, on: nwPort) else { return false }
        listener = l
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global())
            self?.receive(conn)
        }
        l.start(queue: .global())
        return true
    }

    private func receive(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data, let req = String(data: data, encoding: .utf8) else {
                conn.cancel()
                return
            }
            // GET /callback?code=…&state=… HTTP/1.1
            var code: String?
            var state: String?
            let firstLine = req.split(separator: "\r\n").first.map(String.init) ?? ""
            if let pathPart = firstLine.split(separator: " ").dropFirst().first,
               let comps = URLComponents(string: String(pathPart)) {
                for q in comps.queryItems ?? [] {
                    if q.name == "code" { code = q.value }
                    if q.name == "state" { state = q.value }
                }
            }
            let ok = code != nil
            let body = ok
                ? "<html><meta charset='utf-8'><body style='font-family:-apple-system;text-align:center;padding-top:90px;background:#1c1c1e;color:#eee'><h2>✅ 授权完成</h2><p>可以关闭此页面,回到小组件查看用量。</p></body></html>"
                : "<html><meta charset='utf-8'><body style='font-family:-apple-system;text-align:center;padding-top:90px'><h2>未收到授权码</h2></body></html>"
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in
                conn.cancel()
            })
            if let c = code {
                self.onCode(c, state ?? "")
            }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

final class AuthManager: ObservableObject {
    enum Phase { case idle, awaitingCode, working }
    @Published var phase: Phase = .idle
    @Published var message: String?
    @Published var autoMode = false
    var onLoggedIn: () -> Void = {}

    private var verifier = ""
    private var stateParam = ""
    private var redirectUsed = OAuth.redirect
    private let server = CallbackServer()

    func beginLogin() {
        verifier = OAuth.randomB64URL(32)
        stateParam = verifier // 与 Claude Code 登录流程一致
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).b64url

        // 优先本地回调:授权后浏览器自动送回授权码,无需手动粘贴
        autoMode = server.start(port: 54545)
        server.onCode = { [weak self] code, st in
            DispatchQueue.main.async {
                guard let self, self.phase == .awaitingCode else { return }
                self.exchange(code: code, state: st.isEmpty ? self.stateParam : st)
            }
        }
        redirectUsed = autoMode ? "http://localhost:54545/callback" : OAuth.redirect

        var c = URLComponents(string: "https://claude.ai/oauth/authorize")!
        var items: [URLQueryItem] = [
            .init(name: "client_id", value: OAuth.clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectUsed),
            .init(name: "scope", value: OAuth.scopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: stateParam),
        ]
        if !autoMode { items.insert(.init(name: "code", value: "true"), at: 0) }
        c.queryItems = items
        NSWorkspace.shared.open(c.url!)
        phase = .awaitingCode
        message = nil
        DebugLog.log("已打开授权页(回调: \(autoMode ? "localhost 自动" : "手动粘贴"))")
    }

    func submit(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 直接粘贴长效令牌(sk-ant-…)也可以
        let compact = trimmed.filter { !$0.isWhitespace }
        if compact.hasPrefix("sk-ant-") && !compact.contains("#") {
            TokenFile.save(WidgetToken(accessToken: compact, refreshToken: nil, expiresAt: nil))
            DebugLog.log("已保存粘贴的长效令牌")
            finishLogin()
            return
        }
        let parts = compact.split(separator: "#", maxSplits: 1).map(String.init)
        exchange(code: parts[0], state: parts.count > 1 ? parts[1] : stateParam)
    }

    private func exchange(code: String, state: String) {
        phase = .working
        var req = URLRequest(url: OAuth.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": OAuth.clientID,
            "redirect_uri": redirectUsed,
            "code_verifier": verifier,
        ])
        req.timeoutInterval = 20

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self else { return }
                let codeNum = (resp as? HTTPURLResponse)?.statusCode ?? -1
                guard err == nil, codeNum == 200, let data,
                      let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let at = o["access_token"] as? String else {
                    let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    DebugLog.log("登录交换失败 HTTP \(codeNum): \(body.prefix(200))")
                    self.message = "登录失败 (HTTP \(codeNum)),请重试"
                    self.phase = .awaitingCode
                    return
                }
                var t = WidgetToken(accessToken: at,
                                    refreshToken: o["refresh_token"] as? String,
                                    expiresAt: nil)
                if let ei = (o["expires_in"] as? NSNumber)?.doubleValue {
                    t.expiresAt = Date().timeIntervalSince1970 + ei
                }
                TokenFile.save(t)
                DebugLog.log("登录成功,令牌已保存")
                self.finishLogin()
            }
        }.resume()
    }

    private func finishLogin() {
        server.stop()
        phase = .idle
        message = nil
        onLoggedIn()
    }
}

// MARK: - 全局热键:⌃⌥T 显示/隐藏

final class HotkeyManager {
    var onToggle: () -> Void = {}
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// 系统级热键(RegisterEventHotKey):无需辅助功能权限,
    /// 按键被系统直接吞掉,不会打进任何文本框,重新编译也不失效。
    func start() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let m = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { m.onToggle() }
                return noErr
            },
            1, &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        let id = EventHotKeyID(signature: OSType(0x5457_4B54), id: 1) // 'TWKT'
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_T),
                                         UInt32(controlKey | optionKey), // ⌃⌥T
                                         id, GetEventDispatcherTarget(), 0, &hotKeyRef)
        DebugLog.log(status == noErr ? "热键 ⌃⌥T 注册成功(系统级)" : "热键注册失败 status \(status)")
    }
}

// MARK: - Liquid Glass 底层:取景桌面的系统毛玻璃(maskImage 保证圆角不被一刀切)

struct VisualEffectBlur: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.maskImage = .roundedMask(radius: cornerRadius)
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

extension NSImage {
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }
}

// MARK: - 桌宠:Claude 小螃蟹

enum CrabMood { case normal, working, tired, panic, sleeping }

let crabOrange = Color(red: 0.93, green: 0.45, blue: 0.30)
let crabOrangeDark = Color(red: 0.76, green: 0.32, blue: 0.19)

/// 纯矢量小螃蟹,所有动画由时间驱动(眨眼/摆动/走路/敲钳)
struct CrabView: View {
    let date: Date
    let mood: CrabMood
    let walking: Bool
    let facingRight: Bool
    let waving: Bool
    let snapUntil: Date

    var body: some View {
        let t = date.timeIntervalSinceReferenceDate
        let active = walking || mood == .working || mood == .panic
        let bobSpeed: Double = mood == .panic ? 9 : (mood == .working ? 5 : 1.6)
        let bob: CGFloat = mood == .sleeping ? 1.5 : CGFloat(sin(t * bobSpeed)) * (active ? 1.6 : 0.8)
        let legUp = active && (Int(t / 0.22) % 2 == 0)
        let blink = mood == .sleeping || (Int(t * 1.7) % 11 == 0)
        let clawRaise: CGFloat = (waving || mood == .working) ? -4 : 0
        let jitter: CGFloat = mood == .panic ? CGFloat(sin(t * 25)) * 1.2 : 0
        // 钳子开合:悬停打招呼 / 随机触发时快速开合夹击
        let snapping = waving || date < snapUntil
        let openDeg: Double = snapping ? abs(sin(t * 8)) * 48 + 8 : (mood == .working ? 18 : 10)

        ZStack {
            // 六条小腿
            HStack(spacing: 3.5) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule().fill(crabOrangeDark).frame(width: 2.5, height: 8)
                }
            }
            .rotationEffect(.degrees(legUp ? 14 : -5), anchor: .top)
            .offset(x: -11, y: 12)
            HStack(spacing: 3.5) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule().fill(crabOrangeDark).frame(width: 2.5, height: 8)
                }
            }
            .rotationEffect(.degrees(legUp ? -14 : 5), anchor: .top)
            .offset(x: 11, y: 12)

            // 胳膊
            arm.rotationEffect(.degrees(-28)).offset(x: -19, y: -5)
            arm.rotationEffect(.degrees(28)).offset(x: 19, y: -5)

            // 大钳子(可开合夹击;干活时交替敲击,悬停/干活时举起)
            clawShape(openDeg)
                .scaleEffect(x: -1)
                .offset(x: -27, y: -8 + clawRaise + (mood == .working && legUp ? -3 : 0))
            clawShape(openDeg)
                .offset(x: 27, y: -8 + clawRaise + (mood == .working && !legUp ? -3 : 0))

            // 身体
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(LinearGradient(colors: [crabOrange, crabOrangeDark],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 36, height: 24)
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 0.8)
                )

            // 大眼睛
            eye(blink: blink, lookRight: facingRight).offset(x: -7, y: -5)
            eye(blink: blink, lookRight: facingRight).offset(x: 7, y: -5)

            // 嘴(慌张时张成 O 形)
            if mood == .panic {
                Circle().fill(.black.opacity(0.45)).frame(width: 5, height: 5).offset(y: 4)
            } else {
                Capsule().fill(.black.opacity(0.35)).frame(width: 7, height: 1.6).offset(y: 4)
            }

            // 状态挂件
            if mood == .sleeping {
                Text("💤").font(.system(size: 10))
                    .offset(x: 17, y: -14 + CGFloat(sin(t * 1.2)) * 2.5)
            }
            if mood == .tired {
                Circle()
                    .fill(Color(red: 0.5, green: 0.75, blue: 1).opacity(0.85))
                    .frame(width: 4, height: 5)
                    .offset(x: 15, y: -9 + CGFloat((t * 5).truncatingRemainder(dividingBy: 5)))
            }
        }
        .frame(width: 68, height: 42)
        .offset(x: jitter, y: bob)
    }

    private var arm: some View {
        Capsule().fill(crabOrangeDark).frame(width: 12, height: 3.5)
    }

    private func clawShape(_ openDeg: Double) -> some View {
        PincerShape(openDegrees: openDeg)
            .fill(LinearGradient(colors: [crabOrange, crabOrangeDark],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(PincerShape(openDegrees: openDeg).stroke(crabOrangeDark.opacity(0.85), lineWidth: 0.9))
            .frame(width: 17, height: 17)
    }

    private func eye(blink: Bool, lookRight: Bool) -> some View {
        ZStack {
            Circle().fill(.white).frame(width: 9, height: 9)
            if blink {
                Capsule().fill(crabOrangeDark).frame(width: 8, height: 2)
            } else {
                Circle().fill(.black).frame(width: 4, height: 4)
                    .offset(x: lookRight ? 1.5 : -1.5)
            }
        }
    }
}

/// 钳子形状:开口角度可变的扇形缺口圆
struct PincerShape: Shape {
    var openDegrees: Double
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        p.move(to: c)
        p.addArc(center: c, radius: r,
                 startAngle: .degrees(openDegrees / 2),
                 endAngle: .degrees(360 - openDegrees / 2),
                 clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// 桌宠行为控制:闲逛、跳跃、转圈、气泡台词、心情切换
final class CrabController: ObservableObject {
    @Published var x: CGFloat = 30
    @Published var walking = false
    @Published var facingRight = true
    @Published var bubble: String?
    @Published var jumpY: CGFloat = 0
    @Published var spin: Double = 0
    @Published var snapUntil = Date.distantPast

    var mood: CrabMood = .normal
    var zoneWidth: CGFloat = 268
    var quipProvider: () -> String = { "🦀" }

    private var timer: Timer?
    private var bubbleSeq = 0
    private var lastSessionPct: Double?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        guard bubble == nil else { return }
        switch mood {
        case .sleeping:
            return
        case .panic:
            if Int.random(in: 0..<2) == 0 { wander(speed: 60) }
        case .working:
            if Int.random(in: 0..<6) == 0 { wander(speed: 34) }
        default:
            if Int.random(in: 0..<5) == 0 { snapUntil = Date().addingTimeInterval(1.3) } // 随机夹击
            if Int.random(in: 0..<4) == 0 { wander(speed: 26) }
        }
    }

    private func wander(speed: CGFloat) {
        guard !walking else { return }
        let target = CGFloat.random(in: 4...max(zoneWidth - 68, 60))
        guard abs(target - x) > 14 else { return }
        facingRight = target > x
        walking = true
        let dur = Double(abs(target - x) / speed)
        withAnimation(.easeInOut(duration: dur)) { x = target }
        DispatchQueue.main.asyncAfter(deadline: .now() + dur) { [weak self] in
            self?.walking = false
        }
    }

    func poke() {
        DebugLog.log("戳了螃蟹")
        withAnimation(.interpolatingSpring(stiffness: 260, damping: 12)) { jumpY = -13 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            withAnimation(.interpolatingSpring(stiffness: 200, damping: 14)) { self?.jumpY = 0 }
        }
        say(quipProvider())
    }

    func spinAround() {
        withAnimation(.easeInOut(duration: 0.6)) { spin += 360 }
        say("转圈圈~ 🌀")
    }

    func say(_ s: String) {
        bubbleSeq += 1
        let seq = bubbleSeq
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { bubble = s }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, self.bubbleSeq == seq else { return }
            withAnimation(.easeOut(duration: 0.25)) { self.bubble = nil }
        }
    }

    func updateMood(_ m: CrabMood, sessionPct: Double?) {
        mood = m
        // 会话窗口重置(百分比骤降)→ 庆祝
        if let p = sessionPct, let last = lastSessionPct, p < last - 30 {
            say("🎉 会话窗口重置啦!")
        }
        if let p = sessionPct { lastSessionPct = p }
    }
}

// MARK: - 视图

let accentOrange = Color(red: 1.0, green: 0.48, blue: 0.25)
let accentPink   = Color(red: 0.95, green: 0.33, blue: 0.55)
let accentGrad = LinearGradient(colors: [accentOrange, accentPink],
                                startPoint: .leading, endPoint: .trailing)
let barYellow = Color(red: 0.96, green: 0.67, blue: 0.22)
let barBlue   = Color(red: 0.33, green: 0.52, blue: 0.95)
let barRed    = Color(red: 1.0, green: 0.36, blue: 0.34)

struct PulsingDot: View {
    let active: Bool
    @State private var on = false
    var body: some View {
        Circle()
            .fill(active ? Color(red: 0.35, green: 0.9, blue: 0.5) : Color.gray.opacity(0.6))
            .frame(width: 6, height: 6)
            .shadow(color: active ? .green.opacity(0.8) : .clear, radius: 4)
            .opacity(active ? (on ? 1 : 0.3) : 0.8)
            .animation(active ? .easeInOut(duration: 1).repeatForever(autoreverses: true) : .default, value: on)
            .onAppear { on = true }
    }
}

struct WidgetView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var limits: LimitsStore
    @ObservedObject var auth: AuthManager
    var onHeightChange: (CGFloat) -> Void = { _ in }
    @StateObject private var crab = CrabController()
    @State private var hovering = false
    @State private var crabHover = false
    @State private var histMode = false
    @State private var authCode = ""

    private let corner: CGFloat = 24

    var body: some View {
        let now = store.lastRefresh
        let stats = Stats.compute(events: store.events, now: now)
        let isLive = (stats.lastEvent.map { now.timeIntervalSince($0) < 120 }) ?? false

        VStack(spacing: 0) {
            crabZone(stats: stats, now: now)
            VStack(alignment: .leading, spacing: 11) {
                header(isLive: isLive)
                bigNumber(stats)
                sparklineCard(stats)
                limitsCard(now: now)
            }
            .padding(15)
            .frame(width: 268)
            .background {
                ZStack {
                    VisualEffectBlur(cornerRadius: corner)
                    LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.04), .clear],
                                   startPoint: .topLeading, endPoint: .center)
                    RadialGradient(colors: [accentOrange.opacity(0.14), .clear],
                                   center: .topTrailing, startRadius: 0, endRadius: 300)
                    RadialGradient(colors: [accentPink.opacity(0.09), .clear],
                                   center: .bottomLeading, startRadius: 0, endRadius: 280)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.07), .white.opacity(0.22)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1
                    )
            }
        }
        .background(
            // 从内容内部上报真实高度,驱动窗口尺寸,杜绝上下裁切
            GeometryReader { g in
                Color.clear
                    .onAppear {
                        DebugLog.log("内容高度上报(onAppear): \(Int(g.size.height))")
                        onHeightChange(g.size.height)
                    }
                    .onChange(of: g.size.height) { h in
                        DebugLog.log("内容高度上报(变化): \(Int(h))")
                        onHeightChange(h)
                    }
            }
        )
        .onHover { hovering = $0 }
        .onAppear { crab.start() }
        .onReceive(store.$lastRefresh) { now in
            let stats = Stats.compute(events: store.events, now: now)
            let sessionPct = limits.rows.first(where: { $0.isSession })?.pct
            crab.updateMood(crabMood(stats: stats, now: now), sessionPct: sessionPct)
            crab.quipProvider = { [weak limits] in
                var opts = ["咔嚓咔嚓 🦀", "别戳啦,我在打工", "摸鱼 5 分钟不过分吧", "今天也要加油鸭!"]
                opts.append("今日已花 \(fmtMoney(stats.todayCost))")
                if let s = limits?.rows.first(where: { $0.isSession }) {
                    opts.append("会话用了 \(Int(s.pct))% 啦")
                    if let d = s.resetsAt, d > now {
                        opts.append("\(fmtRemain(d.timeIntervalSince(now)))后满血复活")
                    }
                }
                return opts.randomElement() ?? "🦀"
            }
        }
    }

    // 螃蟹的心情与真实用量联动
    private func crabMood(stats: Stats, now: Date) -> CrabMood {
        let sessionPct = limits.rows.first(where: { $0.isSession })?.pct ?? 0
        let idle = stats.lastEvent.map { now.timeIntervalSince($0) } ?? .infinity
        if sessionPct >= 95 { return .panic }
        if idle < 120 { return .working }
        if sessionPct >= 80 { return .tired }
        if idle > 1800 { return .sleeping }
        return .normal
    }

    private func crabZone(stats: Stats, now: Date) -> some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
            Text(crab.bubble ?? " ")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.black.opacity(0.55), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                .opacity(crab.bubble == nil ? 0 : 1)
                .scaleEffect(crab.bubble == nil ? 0.6 : 1, anchor: .bottom)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: crab.bubble)
                .offset(x: min(max(crab.x - 16, 2), 268 - 130), y: -44)
                .allowsHitTesting(false) // 气泡不拦截点击(否则会挡住螃蟹)
            TimelineView(.periodic(from: .now, by: 0.2)) { tl in
                CrabView(date: tl.date,
                         mood: crabMood(stats: stats, now: now),
                         walking: crab.walking,
                         facingRight: crab.facingRight,
                         waving: crabHover,
                         snapUntil: crab.snapUntil)
            }
            .rotationEffect(.degrees(crab.spin))
            .offset(x: crab.x, y: crab.jumpY + 3)
            .onHover { crabHover = $0 }
        }
        .frame(width: 268, height: 64, alignment: .bottomLeading)
        // 整条螃蟹活动带都可点击,目标更大更好戳
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { crab.spinAround() }
        .onTapGesture { crab.poke() }
    }

    private func header(isLive: Bool) -> some View {
        HStack(spacing: 7) {
            PulsingDot(active: isLive)
            Text("Claude 用量")
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
            if isLive {
                Text("LIVE")
                    .font(.system(size: 7.5, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color(red: 0.35, green: 0.9, blue: 0.5))
                    .padding(.horizontal, 4).padding(.vertical, 1.5)
                    .background(Color.green.opacity(0.15), in: Capsule())
            }
            Spacer()
            Text("⌃⌥T")
                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.3))
                .opacity(hovering ? 1 : 0)
            Button { (NSApp.delegate as? AppDelegate)?.toggleWindow() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 16, height: 16)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("隐藏小组件(⌃⌥T 或点菜单栏图标唤回;退出请右键菜单栏图标)")
        }
    }

    private func bigNumber(_ stats: Stats) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("今日费用")
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
            Text(fmtMoney(stats.todayCost))
                .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(accentGrad)
                .shadow(color: accentOrange.opacity(0.3), radius: 10)
            Text("\(fmtTokens(stats.todayTokens)) tokens · \(stats.todayRequests) 次请求")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sparklineCard(_ stats: Stats) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(histMode
                     ? "近 7 天 · 共 \(fmtMoney(stats.daily.reduce(0) { $0 + $1.cost }))"
                     : "近 60 分钟")
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                modeChip("60分", selected: !histMode) { histMode = false }
                modeChip("7天", selected: histMode) { histMode = true }
            }
            if histMode {
                dailyChart(stats)
            } else {
                minuteChart(stats)
            }
        }
        .padding(9)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func modeChip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(selected ? .white : .white.opacity(0.4))
                .padding(.horizontal, 6).padding(.vertical, 2.5)
                .background(selected ? .white.opacity(0.14) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func minuteChart(_ stats: Stats) -> some View {
        Canvas { ctx, size in
            let buckets = stats.sparkline
            let maxV = max(buckets.max() ?? 1, 1)
            let n = buckets.count
            let gap: CGFloat = 1.5
            let bw = (size.width - gap * CGFloat(n - 1)) / CGFloat(n)
            for (i, v) in buckets.enumerated() {
                let ratio: CGFloat = v <= 0 ? 0.06 : max(0.12, CGFloat(sqrt(v / maxV)))
                let h = size.height * ratio
                let rect = CGRect(x: CGFloat(i) * (bw + gap), y: size.height - h, width: bw, height: h)
                let path = Path(roundedRect: rect, cornerRadius: bw / 2)
                if v <= 0 {
                    ctx.fill(path, with: .color(.white.opacity(0.10)))
                } else {
                    ctx.fill(path, with: .linearGradient(
                        Gradient(colors: [accentPink, accentOrange]),
                        startPoint: CGPoint(x: 0, y: size.height),
                        endPoint: CGPoint(x: 0, y: 0)))
                }
            }
        }
        .frame(height: 26)
    }

    private func dailyChart(_ stats: Stats) -> some View {
        Canvas { ctx, size in
            let days = stats.daily
            guard !days.isEmpty else { return }
            let maxV = max(days.map(\.cost).max() ?? 0.01, 0.01)
            let n = days.count
            let gap: CGFloat = 5
            let bw = (size.width - gap * CGFloat(n - 1)) / CGFloat(n)
            let chartH = size.height - 11
            for (i, d) in days.enumerated() {
                let ratio: CGFloat = d.cost <= 0 ? 0.05 : max(0.09, CGFloat(d.cost / maxV))
                let h = chartH * ratio
                let x = CGFloat(i) * (bw + gap)
                let isToday = i == n - 1
                let path = Path(roundedRect: CGRect(x: x, y: chartH - h, width: bw, height: h),
                                cornerRadius: 3)
                if d.cost <= 0 {
                    ctx.fill(path, with: .color(.white.opacity(0.08)))
                } else {
                    var c = ctx
                    c.opacity = isToday ? 1 : 0.5
                    c.fill(path, with: .linearGradient(
                        Gradient(colors: [accentPink, accentOrange]),
                        startPoint: CGPoint(x: 0, y: chartH),
                        endPoint: CGPoint(x: 0, y: 0)))
                }
                if isToday && d.cost > 0 {
                    ctx.draw(Text(fmtMoney(d.cost))
                                .font(.system(size: 6.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.85)),
                             at: CGPoint(x: x + bw / 2, y: max(chartH - h - 6, 5)))
                }
                ctx.draw(Text(weekdayShort.string(from: d.day))
                            .font(.system(size: 6.5))
                            .foregroundStyle(.white.opacity(isToday ? 0.8 : 0.4)),
                         at: CGPoint(x: x + bw / 2, y: size.height - 3.5))
            }
        }
        .frame(height: 48)
    }

    private func limitsCard(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 5) {
                Image(systemName: "gauge.with.needle")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Text("套餐用量")
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
            }
            if limits.needsAuth {
                loginSection
            } else if let e = limits.errorText {
                Text("⚠️ \(e)")
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundStyle(barYellow.opacity(0.95))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if limits.rows.isEmpty && limits.errorText == nil && !limits.needsAuth {
                Text("加载中…")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
            }
            ForEach(limits.rows) { r in
                limitRow(r, now: now)
            }
        }
        .padding(11)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var loginSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch auth.phase {
            case .idle:
                Text("登录后显示官方套餐用量")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    auth.beginLogin()
                } label: {
                    Text("使用 Claude 账号登录")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(accentGrad, in: Capsule())
                }
                .buttonStyle(.plain)
            case .awaitingCode:
                Text(auth.autoMode
                     ? "已打开浏览器,点「授权」后自动完成登录。若页面显示了授权码,也可粘贴到下面:"
                     : "已打开浏览器,授权后把页面显示的授权码粘贴到这里:")
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                TextField("粘贴授权码", text: $authCode)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(7)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onSubmit { auth.submit(authCode) }
                HStack(spacing: 10) {
                    Button { auth.submit(authCode) } label: {
                        Text("确认")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 5)
                            .background(accentGrad, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Button { auth.beginLogin() } label: {
                        Text("重新打开授权页")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
                if let m = auth.message {
                    Text(m)
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(barRed)
                }
            case .working:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("验证中…")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }

    private func limitRow(_ r: LimitRow, now: Date) -> some View {
        let pct = min(max(r.pct, 0), 100)
        let color: Color = (r.pct >= 90 || r.severity == "critical") ? barRed
            : (r.isSession ? barYellow : barBlue)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(r.label)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text("\(Int(r.pct.rounded()))%")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.10))
                    Capsule().fill(color)
                        .frame(width: pct > 0 ? max(geo.size.width * pct / 100, 5) : 0)
                }
            }
            .frame(height: 5)
            if let t = resetText(r, now: now) {
                Text(t)
                    .font(.system(size: 8.5, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.42))
            }
        }
    }

    private func resetText(_ r: LimitRow, now: Date) -> String? {
        guard let d = r.resetsAt else { return nil }
        let dt = d.timeIntervalSince(now)
        if dt <= 0 { return "即将重置" }
        if dt < 6 * 3600 { return "\(fmtRemain(dt))后重置" }
        return "\(weekdayHM.string(from: d)) 重置"
    }
}

// MARK: - 玻璃预警弹窗(90% 触发,3 秒后消散分解)

struct GlassAlertView: View {
    let title: String
    let subtitle: String
    @State private var appeared = false
    @State private var dissolving = false

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(barRed.opacity(0.18)).frame(width: 34, height: 34)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(barRed)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
                Text(subtitle)
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .frame(width: 320, alignment: .leading)
        .background {
            ZStack {
                VisualEffectBlur(cornerRadius: 18)
                LinearGradient(colors: [.white.opacity(0.18), .clear],
                               startPoint: .topLeading, endPoint: .center)
                RadialGradient(colors: [barRed.opacity(0.15), .clear],
                               center: .topTrailing, startRadius: 0, endRadius: 260)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.08)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1)
        )
        // 入场弹出
        .scaleEffect(appeared ? 1 : 0.9)
        .opacity(appeared ? 1 : 0)
        // 消散分解:放大 + 模糊化开 + 上飘 + 淡出
        .scaleEffect(dissolving ? 1.08 : 1)
        .blur(radius: dissolving ? 16 : 0)
        .offset(y: dissolving ? -18 : 0)
        .opacity(dissolving ? 0 : 1)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { appeared = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation(.easeIn(duration: 0.6)) { dissolving = true }
            }
        }
    }
}

// MARK: - 窗口与入口

final class WidgetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: WidgetWindow?
    let store = UsageStore()
    let limits = LimitsStore()
    let auth = AuthManager()
    let hotkeys = HotkeyManager()
    private var statusItem: NSStatusItem?
    private var hostingRef: NSHostingView<WidgetView>?
    private var bag = Set<AnyCancellable>()
    private var alertWindow: NSWindow?
    private var alertedResetAt: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu() // 提供「编辑」菜单,否则无边框应用里 ⌘V 粘贴不可用
        store.start()
        limits.start()
        auth.onLoggedIn = { [weak self] in self?.limits.fetch(force: true) }

        var applyHeight: (CGFloat) -> Void = { _ in }
        let rootView = WidgetView(store: store, limits: limits, auth: auth,
                                  onHeightChange: { h in applyHeight(h) })
        let hosting = NSHostingView(rootView: rootView)
        hostingRef = hosting
        applyHeight = { [weak self] h in
            DispatchQueue.main.async { self?.applyContentHeight(h) }
        }

        let win = WidgetWindow(contentRect: NSRect(x: 0, y: 0, width: 268, height: 380),
                               styleMask: [.borderless, .fullSizeContentView],
                               backing: .buffered, defer: false)
        win.contentView = hosting
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isMovableByWindowBackground = true
        win.appearance = NSAppearance(named: .darkAqua)
        _ = win.setFrameAutosaveName("TokenWidgetFrame")
        if win.frame.origin == .zero, let screen = NSScreen.main {
            let f = screen.visibleFrame
            win.setFrameOrigin(NSPoint(x: f.maxX - 268 - 24, y: f.maxY - 400 - 24))
        }
        win.makeKeyAndOrderFront(nil)
        window = win

        hotkeys.onToggle = { [weak self] in self?.toggleWindow() }
        hotkeys.start()

        setupStatusItem()
        limits.$rows
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rows in
                self?.updateStatusItem(rows)
                self?.maybeAlert(rows)
            }
            .store(in: &bag)
    }

    /// 窗口尺寸对齐内容真实高度(由 SwiftUI 内部上报,锚定顶边)
    private func applyContentHeight(_ h: CGFloat) {
        guard let win = window else {
            DebugLog.log("收到高度 \(Int(h)) 但窗口尚未创建")
            return
        }
        DebugLog.log("applyContentHeight: 内容 \(Int(h)),窗口当前 \(Int(win.frame.width))×\(Int(win.frame.height))")
        let target = NSSize(width: 268, height: ceil(h))
        guard target.height > 120 else { return }
        let cur = win.frame
        if abs(cur.height - target.height) > 1 || abs(cur.width - target.width) > 1 {
            DebugLog.log("窗口高度对齐内容: \(Int(cur.height)) → \(Int(target.height))")
            let newFrame = NSRect(x: cur.origin.x,
                                  y: cur.maxY - target.height,
                                  width: target.width,
                                  height: target.height)
            win.setFrame(newFrame, display: true)
        }
    }

    // MARK: 菜单栏常驻

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = item.button {
            btn.title = "🦀"
            btn.target = self
            btn.action = #selector(statusItemClicked)
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
            btn.imagePosition = .imageLeft
        }
        statusItem = item
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let toggle = NSMenuItem(title: window?.isVisible == true ? "隐藏面板" : "显示面板",
                                    action: #selector(togglePanelFromMenu), keyEquivalent: "t")
            toggle.target = self
            menu.addItem(toggle)
            let refresh = NSMenuItem(title: "立即刷新用量", action: #selector(refreshNow), keyEquivalent: "r")
            refresh.target = self
            menu.addItem(refresh)
            let login = NSMenuItem(title: "开机自启", action: #selector(toggleLoginItem), keyEquivalent: "")
            login.target = self
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
            return
        }
        toggleFromStatusItem()
    }

    @objc private func refreshNow() { limits.fetch(force: true) }

    @objc private func togglePanelFromMenu() { toggleFromStatusItem() }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                DebugLog.log("已关闭开机自启")
            } else {
                try SMAppService.mainApp.register()
                DebugLog.log("已开启开机自启")
            }
        } catch {
            DebugLog.log("开机自启切换失败: \(error.localizedDescription)")
        }
    }

    private func toggleFromStatusItem() {
        guard let win = window else { return }
        if win.isVisible {
            win.orderOut(nil)
        } else {
            limits.fetch()
            // 面板贴着菜单栏图标下方弹出
            if let btnWin = statusItem?.button?.window,
               let screen = btnWin.screen ?? NSScreen.main {
                let bf = btnWin.frame
                var x = bf.midX - win.frame.width / 2
                x = min(max(x, screen.visibleFrame.minX + 8),
                        screen.visibleFrame.maxX - win.frame.width - 8)
                let y = bf.minY - win.frame.height - 8
                win.setFrameOrigin(NSPoint(x: x, y: y))
            }
            win.orderFrontRegardless()
        }
    }

    private func sessionColor(_ pct: Double) -> NSColor {
        if pct >= 90 { return .systemRed }
        if pct >= 80 { return .systemOrange }
        if pct >= 60 { return .systemYellow }
        return .systemGreen
    }

    private func updateStatusItem(_ rows: [LimitRow]) {
        guard let btn = statusItem?.button else { return }
        guard let s = rows.first(where: { $0.isSession }) else {
            btn.image = nil
            btn.title = "🦀"
            return
        }
        let pct = min(max(s.pct, 0), 100)
        let color = sessionColor(pct)
        // 短进度条
        let img = NSImage(size: NSSize(width: 26, height: 16), flipped: false) { _ in
            let track = NSBezierPath(roundedRect: NSRect(x: 0, y: 5.5, width: 26, height: 5),
                                     xRadius: 2.5, yRadius: 2.5)
            NSColor.white.withAlphaComponent(0.25).setFill()
            track.fill()
            let w = max(26 * pct / 100, 3)
            let fill = NSBezierPath(roundedRect: NSRect(x: 0, y: 5.5, width: w, height: 5),
                                    xRadius: 2.5, yRadius: 2.5)
            color.setFill()
            fill.fill()
            return true
        }
        img.isTemplate = false
        btn.image = img
        btn.attributedTitle = NSAttributedString(
            string: " \(Int(pct.rounded()))%",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
                .foregroundColor: color,
            ])
    }

    // MARK: 90% 用量玻璃预警

    private func maybeAlert(_ rows: [LimitRow]) {
        guard let s = rows.first(where: { $0.isSession }), s.pct >= 90 else { return }
        // 每个 5 小时窗口只提醒一次(以 resets_at 区分窗口)
        if let r = s.resetsAt, let prev = alertedResetAt,
           abs(r.timeIntervalSince(prev)) < 60 { return }
        alertedResetAt = s.resetsAt ?? Date()
        let sub: String
        if let r = s.resetsAt {
            sub = "剩余 \(fmtRemain(r.timeIntervalSince(Date()))) · \(weekdayHM.string(from: r)) 重置"
        } else {
            sub = "注意控制用量"
        }
        showGlassAlert(title: "会话用量已达 \(Int(s.pct))%", subtitle: sub)
    }

    private func showGlassAlert(title: String, subtitle: String) {
        alertWindow?.orderOut(nil)
        let hosting = NSHostingView(rootView: GlassAlertView(title: title, subtitle: subtitle))
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 70),
                           styleMask: [.borderless, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.contentView = hosting
        win.setContentSize(hosting.fittingSize)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = .statusBar
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.appearance = NSAppearance(named: .darkAqua)
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            win.setFrameOrigin(NSPoint(x: f.midX - win.frame.width / 2,
                                       y: f.maxY - win.frame.height - 16))
        }
        win.orderFrontRegardless()
        alertWindow = win
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self, weak win] in
            guard let win, self?.alertWindow === win else { return }
            win.orderOut(nil)
            self?.alertWindow = nil
        }
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        NSApp.mainMenu = main
    }

    func toggleWindow() {
        guard let win = window else { return }
        if win.isVisible {
            win.orderOut(nil)
        } else {
            limits.fetch() // 呼出时立刻刷新一次套餐用量
            win.orderFrontRegardless()
        }
    }
}

@main
enum TokenWidgetApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}
