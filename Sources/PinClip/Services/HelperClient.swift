import Foundation

/// device-helper HTTP 客户端（本地 17877，token 鉴权——helper 端点契约见 app-inspector 项目）
struct HelperClient {
    /// 独立端口 17878：与 app-inspector 的 17877 实例完全隔离（避免 token 顶替冲突）
    static let defaultPort = 17878

    var token: String
    var port: Int = HelperClient.defaultPort

    private var base: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.httpShouldUsePipelining = false
        return URLSession(configuration: cfg)
    }()

    /// /ping 免鉴权：helper 是否存活
    func ping() async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("ping"))
        req.timeoutInterval = 2
        guard let (resp, _) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return true
    }

    /// /clipboard_status：监听注册状态 + seq 基线
    func clipboardStatus() async -> (registered: Bool, seq: Int64)? {
        var req = authorized(request: base.appendingPathComponent("clipboard_status"))
        req.timeoutInterval = 5
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let seq = (obj["seq"] as? NSNumber)?.int64Value ?? 0
        let registered = (obj["registered"] as? NSNumber)?.boolValue ?? (obj["registered"] as? Bool ?? false)
        return (registered, seq)
    }

    /// /wait_clipboard 长轮询：变化立即返回 {seq, changed, text?}，超时 changed=false
    func waitClipboard(seq: Int64, timeoutMs: Int = 25000) async -> (seq: Int64, changed: Bool, text: String?)? {
        var comps = URLComponents(url: base.appendingPathComponent("wait_clipboard"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "seq", value: String(seq)),
            URLQueryItem(name: "timeout_ms", value: String(timeoutMs)),
            URLQueryItem(name: "token", value: token),
        ]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = Double(timeoutMs) / 1000 + 6
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let newSeq = (obj["seq"] as? NSNumber)?.int64Value ?? seq
        let changed = (obj["changed"] as? NSNumber)?.boolValue ?? false
        let text = obj["text"] as? String
        return (newSeq, changed, text)
    }

    /// /action clipboard_set：写入 Android 剪贴板
    func clipboardSet(_ text: String) async -> Bool {
        await action(["cmd": "clipboard_set", "text": text])
    }

    /// /action clipboard_get：读取 Android 剪贴板（部分系统版本对 shell 限读返回空）
    func clipboardGet() async -> String? {
        guard let raw = await actionRaw(["cmd": "clipboard_get"]) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return nil }
        return obj["text"] as? String
    }

    // MARK: - 内部

    private func authorized(request url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(token, forHTTPHeaderField: "X-AppInspector-Token")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    private func action(_ payload: [String: Any]) async -> Bool {
        guard let raw = await actionRaw(payload) else { return false }
        return true
    }

    private func actionRaw(_ payload: [String: Any]) async -> Data? {
        var comps = URLComponents(url: base.appendingPathComponent("action"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "token", value: token)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "X-AppInspector-Token")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 10
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }
}
