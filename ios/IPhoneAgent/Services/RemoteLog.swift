import Foundation
import UIKit
import UserNotifications

/// Remote debug log: a developer's own pull channel for the text debug log (debug.log) of a phone that can't be
/// reached, e.g. on cellular with the board plugged in. Off unless an endpoint URL and token are set (Settings ›
/// Developer, or a `remote-debug-log.json` dropped into Documents). When set, the app polls `<url>/poll` about
/// every 30 s while it is active or a run is going; when the server asks, it uploads the requested tail of
/// debug.log to `<url>/upload` as text/plain, secrets redacted. Never screenshots or other files.
/// Server API: docs/remote-debug-log.md.
struct RemoteLogConfig: Equatable {
    var url = ""
    var token = ""

    static let urlKey = "remoteLogURL"
    static let tokenAccount = "remote-log-token"
    static let dropName = "remote-debug-log.json"

    /// Where to poll, or nil = off: both set, https, a host, no credentials in the URL.
    var endpoint: URL? {
        let text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let parts = URLComponents(string: text),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, let u = parts.url else { return nil }
        return u
    }

    static func load(_ defaults: UserDefaults = .standard) -> Self {
        Self(url: defaults.string(forKey: urlKey) ?? "", token: Keychain.get(tokenAccount) ?? "")
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(url.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.urlKey)
        Keychain.set(token.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.tokenAccount)
    }

    /// `{"url": "...", "token": "..."}`; nil if malformed or not https.
    static func parse(drop data: Data) -> Self? {
        guard let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let url = d["url"] as? String, let token = d["token"] as? String else { return nil }
        let config = Self(url: url, token: token)
        return config.endpoint == nil ? nil : config
    }

    /// Import `Documents/remote-debug-log.json` (e.g. `devicectl device copy to` or Finder file sharing) and delete
    /// it, so no one has to type a token on the phone. Returns whether a config was imported.
    @discardableResult
    static func importDrop(from dir: URL, defaults: UserDefaults = .standard) -> Bool {
        let file = dir.appendingPathComponent(dropName)
        guard let data = try? Data(contentsOf: file) else { return false }
        try? FileManager.default.removeItem(at: file)
        guard let config = parse(drop: data) else {
            DebugLog.write("remote log: ignored a malformed \(dropName)")
            return false
        }
        config.save(defaults)
        DebugLog.write("remote log: configured from \(dropName)")
        return true
    }
}

/// What may go out: strips secrets and anything key-, token- or image-shaped from log text.
enum RemoteLogRedaction {
    private static let mask = Redactor.mask
    private static let rules: [(String, String)] = [
        (#"data:image/[^\s"']*"#, "[image removed]"),
        (#"(?i)\b(authorization|bearer)\b(["']?\s*[:=]?\s*["']?)(bearer\s+)?[A-Za-z0-9._~+/=-]{6,}"#, "$1$2\(mask)"),
        (#"(?i)\b(api[_-]?key|x-api-key|token|secret|password|passwd|pass|pwd|key)\b(["']?\s*[:=]\s*["']?)[^\s"',&;]{4,}"#,
         "$1$2\(mask)"),
        (#"\b(sk|pk|rk|ghp|gho|xox[abp])[-_][A-Za-z0-9_-]{10,}"#, mask),
        (#"\bv1\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#, mask),     // signed tickets
        (#"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}(\.[A-Za-z0-9_-]+)?"#, mask),  // JWTs
        (#"\b[A-Za-z0-9_-]{40,}\b"#, mask),                             // long opaque strings (keys, tokens)
    ]

    static func clean(_ text: String, secrets: [String]) -> String {
        var out = Redactor(secrets: secrets).text(text)  // exact secrets, IPs, typed text
        for (pattern, template) in rules {
            out = out.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return out
    }

    /// The values this app knows are secret: model, Jev and free-line keys and the channel's own token.
    @MainActor static func knownSecrets(_ config: RemoteLogConfig) -> [String] {
        var keys = ["llm-api-key", JevConfig.keychainAccount, "trial-device-token", "trial-pending-token"]
            .compactMap { Keychain.get($0) }
        if let base = UserDefaults.standard.string(forKey: "baseURL") { keys += Keychain.get("llm-endpoint-" + base).map { [$0] } ?? [] }
        return (keys + [config.token]).filter { $0.count >= 4 }
    }
}

/// The server's answer to a poll: `{"want": {"id", "minutes" | "lines"}}` or `{}`.
struct RemoteLogWant: Decodable, Equatable {
    var id: String
    var minutes: Int?
    var lines: Int?
}

protocol RemoteLogTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

struct URLSessionRemoteLogTransport: RemoteLogTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

@MainActor final class RemoteLog {
    static let shared = RemoteLog()
    static let interval: UInt64 = 30_000_000_000
    static let maxBytes = 1_900_000  // the server takes ≤ 2 MB

    var transport: RemoteLogTransport = URLSessionRemoteLogTransport()
    var config: () -> RemoteLogConfig = { RemoteLogConfig.load() }
    var logText: () -> String = { DebugLog.allText() }
    var secrets: (RemoteLogConfig) -> [String] = { RemoteLogRedaction.knownSecrets($0) }
    var now: () -> Date = { Date() }
    private(set) var lastUpload: Date?
    private var lastError = ""

    /// One poll, and the upload it asks for. No network at all when not configured. Returns the upload's id.
    @discardableResult
    func tick() async -> String? {
        let config = config()
        guard let base = config.endpoint else { return nil }
        do {
            let (data, status) = try await transport.send(request(base, "poll", config.token, body: Data("{}".utf8),
                                                                  type: "application/json"))
            guard status == 200 else { throw Failure.status("poll", status) }
            struct Reply: Decodable { var want: RemoteLogWant? }
            guard let want = try JSONDecoder().decode(Reply.self, from: data).want else { return nil }
            let text = Self.tail(logText(), want: want, now: now())
            let clean = RemoteLogRedaction.clean(text, secrets: secrets(config))
            var up = request(base, "upload", config.token, body: Data(Self.capped(clean).utf8), type: "text/plain; charset=utf-8")
            up.setValue(want.id, forHTTPHeaderField: "X-Request-Id")
            let (_, upStatus) = try await transport.send(up)
            guard upStatus == 200 else { throw Failure.status("upload", upStatus) }
            lastUpload = now()
            lastError = ""
            DebugLog.write("remote log: uploaded \(clean.split(separator: "\n").count) lines for request \(want.id)")
            return want.id
        } catch {
            let line = "\(error)"
            if line != lastError { DebugLog.write("remote log: \(line.prefix(120))") }  // once per kind of failure
            lastError = line
            return nil
        }
    }

    private enum Failure: Error, CustomStringConvertible {
        case status(String, Int)
        var description: String {
            switch self { case let .status(what, code): return "\(what) failed: HTTP \(code)" }
        }
    }

    private func request(_ base: URL, _ path: String, _ token: String, body: Data, type: String) -> URLRequest {
        var r = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 20)
        r.httpMethod = "POST"
        r.httpBody = body
        r.setValue(type, forHTTPHeaderField: "Content-Type")
        r.setValue("Bearer " + token.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "Authorization")
        return r
    }

    /// The asked-for part of the log: the last `lines` lines, or the lines stamped within the last `minutes`
    /// (an unstamped line follows the one before it).
    static func tail(_ text: String, want: RemoteLogWant, now: Date) -> String {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
        if let n = want.lines { return all.suffix(max(0, min(n, 50_000))).joined(separator: "\n") + "\n" }
        let cutoff = now.addingTimeInterval(-Double(max(1, min(want.minutes ?? 10, 1440))) * 60)
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var keep = false
        let picked = all.filter { line in
            if let first = line.split(separator: " ", maxSplits: 1).first, let t = stamp.date(from: String(first)) {
                keep = t >= cutoff
            }
            return keep
        }
        return picked.isEmpty ? "" : picked.joined(separator: "\n") + "\n"
    }

    /// At most maxBytes, keeping the end (whole lines).
    static func capped(_ text: String) -> String {
        let data = Data(text.utf8)
        guard data.count > maxBytes else { return text }
        let tail = data.suffix(maxBytes)
        let start = tail.firstIndex(of: 10).map { $0 + 1 } ?? tail.startIndex
        return String(decoding: tail[start...], as: UTF8.self)
    }
}

extension AppModel {
    /// Polls while the app is active or a run is going (the BLE background mode keeps a run's process alive);
    /// a suspended app just skips. Not configured: only the local check for a dropped config file.
    func startRemoteLog() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        Task { [weak self] in
            while !Task.isCancelled {
                RemoteLogConfig.importDrop(from: docs)
                guard let self else { return }
                if !self.isBackground() || self.agent.running { await RemoteLog.shared.tick() }
                try? await Task.sleep(nanoseconds: RemoteLog.interval)
            }
        }
    }
}

// MARK: - Remote tasks (fork: an outside agent sends a task, the app runs it and posts the answer back)

/// Its own switch (off by default), URL and token: the debug-log token never controls the phone, and a dropped
/// remote-debug-log.json never turns this on. Set only in Settings › Developer › Remote tasks.
/// Server API:
///   POST <url>/task    `{}` → `{"task": {"id": "t1", "text": "open Notes and write hello"}}` or `{}` (nothing queued)
///   POST <url>/result  `{"id", "outcome": "done|failed|stopped|not_started|unknown", "answer", "steps", "seconds", "run"}` → 200
/// Tasks run unattended (RunPolicy.unattended). The answer goes back as the run wrote it, not redacted.
struct RemoteTaskConfig: Equatable {
    var enabled = false
    var url = ""
    var token = ""

    static let enabledKey = "remoteTasksEnabled"
    static let urlKey = "remoteTasksURL"
    static let tokenAccount = "remote-tasks-token"

    /// Where to poll, or nil = off: switched on, both set, https (the same checks as the debug log).
    var endpoint: URL? { enabled ? RemoteLogConfig(url: url, token: token).endpoint : nil }

    static func load(_ defaults: UserDefaults = .standard) -> Self {
        Self(enabled: defaults.bool(forKey: enabledKey), url: defaults.string(forKey: urlKey) ?? "",
             token: Keychain.get(tokenAccount) ?? "")
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Self.enabledKey)
        defaults.set(url.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.urlKey)
        Keychain.set(token.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.tokenAccount)
    }
}

@MainActor final class RemoteTasks {
    static let shared = RemoteTasks()
    static let interval: UInt64 = 15_000_000_000
    static let pendingKey = "remoteTaskPending"   // {id, run}: survives a relaunch mid-run, so the result still goes back

    var transport: RemoteLogTransport = URLSessionRemoteLogTransport()
    var config: () -> RemoteTaskConfig = { RemoteTaskConfig.load() }
    /// The ids whose report is being sent right now: the stale path leaves them alone.
    var reporting: Set<String> = []
    private var lastError = ""

    struct Pending: Codable, Equatable { var id: String; var run: String }

    /// The remote task whose run is going (or ended without its result reaching the server).
    var pending: Pending? {
        get { UserDefaults.standard.data(forKey: Self.pendingKey).flatMap { try? JSONDecoder().decode(Pending.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.pendingKey) }
    }

    struct Queued: Decodable { var id: String; var text: String }

    /// Ids are echoed back to the server and logged: short and plain only.
    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// One poll. Returns the queued task, if any; no network when not switched on and configured.
    func next() async -> Queued? {
        let config = config()
        guard let base = config.endpoint else { return nil }
        do {
            let (data, status) = try await transport.send(request(base, "task", config.token, body: Data("{}".utf8)))
            guard status == 200 else { throw URLError(.badServerResponse, userInfo: ["status": status]) }
            struct Reply: Decodable { var task: Queued? }
            lastError = ""
            guard let task = try JSONDecoder().decode(Reply.self, from: data).task else { return nil }
            guard Self.validID(task.id) else {
                DebugLog.write("remote task: ignored a task with a malformed id")
                return nil
            }
            return task
        } catch {
            let line = "\(error)"
            if line != lastError { DebugLog.write("remote task: poll failed: \(line.prefix(120))") }
            lastError = line
            return nil
        }
    }

    /// Posts a result, retrying a few times (cellular on the board hotspot can drop for a moment). Pending is
    /// cleared only when the server took it (HTTP 200); else the stale path tries again later.
    /// claimed: the caller already put id in `reporting` (reportRemoteTask does, before its Task runs).
    func report(_ id: String, outcome: String, answer: String, steps: Int = 0, seconds: Int = 0, run: String = "",
                claimed: Bool = false) async {
        guard claimed || !reporting.contains(id) else { return }
        reporting.insert(id)
        defer { reporting.remove(id) }
        let config = config()
        guard let base = config.endpoint else { return }
        var background = UIBackgroundTaskIdentifier.invalid
        background = UIApplication.shared.beginBackgroundTask(withName: "remote-task-result") {
            UIApplication.shared.endBackgroundTask(background)
            background = .invalid
        }
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
        let body: [String: Any] = ["id": id, "outcome": outcome, "answer": answer, "steps": steps, "seconds": seconds, "run": run]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt * 5) * 1_000_000_000) }
            if let (_, status) = try? await transport.send(request(base, "result", config.token, body: data)), status == 200 {
                DebugLog.write("remote task: result sent for \(id) (\(outcome))")
                if pending?.id == id { pending = nil }
                return
            }
        }
        DebugLog.write("remote task: could not send the result for \(id); kept for the next poll")
    }

    /// The local notice each time a task arrives, so the phone's owner sees what was asked.
    func announce(_ text: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Remote task received")
        content.body = String(text.prefix(200))
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "remote-task-\(UUID().uuidString)",
                                                                     content: content, trigger: nil))
    }

    private func request(_ base: URL, _ path: String, _ token: String, body: Data) -> URLRequest {
        var r = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 20)
        r.httpMethod = "POST"
        r.httpBody = body
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Bearer " + token.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "Authorization")
        return r
    }

    /// Added to every remote task: a question is answered by looking, not by changing things (2026-11-23: "tell me
    /// the battery percentage" turned the Battery Percentage switch on).
    static let readOnlyNote = "\n\n(Sent remotely. If this asks for information, only look and report it in your final answer; "
        + "don't change settings, send, buy or delete anything unless the task says to.)"

    static func name(_ outcome: Outcome) -> String {
        switch outcome {
        case .done: return "done"
        case .stopped: return "stopped"
        case .failed, .running: return "failed"
        }
    }
}

extension AppModel {
    /// Polls for a task every 15 s while nothing runs; does nothing (no network) unless Remote tasks is switched on.
    /// It also polls in the background while the board is connected: the board's 1 s BLE status heartbeat
    /// (bluetooth-central background mode) is what keeps this process alive then. A suspended app just skips.
    func startRemoteTasks() {
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.remoteTaskTick()
                try? await Task.sleep(nanoseconds: RemoteTasks.interval)
            }
        }
    }

    private var remoteIdle: Bool { !agent.running && !startingAgent && !recorder.busy && !calibrator.busy }

    private func remoteTaskTick() async {
        let remote = RemoteTasks.shared
        guard remote.config().endpoint != nil else { return }
        if let stale = remote.pending {
            // A run that ended while its result couldn't be sent, or a process that ended mid-run. Its own run
            // only (never the newest one, which may be the user's); a report already in flight is left alone.
            guard remoteIdle, !remote.reporting.contains(stale.id) else { return }
            runs.reload()
            let run = stale.run.isEmpty ? nil : runs.run(stale.run)
            let last = run?.steps.last?.action
            await remote.report(stale.id, outcome: run.map { RemoteTasks.name($0.outcome) } ?? "unknown",
                                answer: last?["answer"]?.str ?? last?["reason"]?.str ?? "", run: stale.run)
            return
        }
        guard remoteIdle, !isBackground() || board.connected else { return }
        guard let task = await remote.next() else { return }
        DebugLog.write("remote task: \(task.id) received")
        remote.announce(task.text)
        let text = task.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // "continue" and calls take special paths (the last turn, the call guide): not for remote tasks.
        if ChatContext.isContinue(text) || Calls.isCall(text, kind: nil) {
            return await remote.report(task.id, outcome: "not_started", answer: "Remote tasks can't continue a run or place calls.")
        }
        guard remoteIdle else {  // the user started something while the poll was out
            return await remote.report(task.id, outcome: "not_started", answer: "The phone was busy.")
        }
        remoteRunStarting = task.id
        let said = await handle(.runTask(text + RemoteTasks.readOnlyNote, unattended: true))
        remoteRunStarting = nil
        remoteClaim = nil
        // Started: claimRemoteRun() saved {id, run} when the agent started; ended() reports the real result.
        if remoteRunsStarted.remove(task.id) != nil { return }
        // Never started. `said` is the reason ("Could not start: …"); a run going now is someone else's.
        await remote.report(task.id, outcome: "not_started",
                            answer: agent.running ? "The phone was busy with another run." : said)
    }

    /// From startAgent, right after the agent started: the run this remote task started, by its run ID.
    func claimRemoteRun() {
        guard let id = remoteClaim else { return }
        remoteClaim = nil
        RemoteTasks.shared.pending = .init(id: id, run: runID)
        remoteRunsStarted.insert(id)
        DebugLog.write("remote task: \(id) runs as \(runID)")
    }

    /// From ended(): the finished run's answer goes back to whoever queued it, only if this is that task's run.
    func reportRemoteTask(outcome: Outcome, last: JObject?, seconds: Double) {
        let remote = RemoteTasks.shared
        let id: String
        guard let p = remote.pending, !p.run.isEmpty, p.run == runID else { return }
        id = p.id
        let answer = last?["answer"]?.str ?? last?["message"]?.str ?? last?["reason"]?.str ?? ""
        let steps = moveCount, run = runID
        guard !remote.reporting.contains(id) else { return }
        remote.reporting.insert(id)  // now, so a poll before the Task runs can't report it too
        Task {
            await remote.report(id, outcome: RemoteTasks.name(outcome), answer: answer, steps: steps, seconds: Int(seconds),
                                run: run, claimed: true)
        }
    }
}
