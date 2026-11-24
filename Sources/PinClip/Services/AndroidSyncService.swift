import AppKit
import Foundation

/// Android 剪贴板双向同步（复用 app-inspector device-helper：scrcpy-server 式零安装）
///
/// - Mac → Android：Mac 剪贴板变化 → `/action clipboard_set`（Android 写剪贴板不受限；helper 仅支持文本）
/// - Android → Mac：`/wait_clipboard` 长轮询（变化监听器 + 按内容去重，helper 已内置防循环）
///   → 入 PinClip 历史（来源「Android · 设备名」，过与剪贴板监听同一套隐私过滤）
/// - 连接要求：USB 或无线调试 ADB 连接；断线自动重连（连续两错重建会话）
@MainActor
@Observable
final class AndroidSyncService {
    enum ConnectionState: String {
        case idle = "未接入"
        case connecting = "接入中…"
        case connected = "已连接"
        case error = "连接失败"
    }

    private(set) var connectionState: ConnectionState = .idle
    private(set) var deviceName = ""
    private(set) var deviceSerial = ""
    private(set) var lastError: String?

    var pollTask: Task<Void, Never>?
    var helperProcess: Process?
    var helperToken = UUID().uuidString
    private var lastSeq: Int64 = 0
    private var errorStreak = 0
    private var adbURL: URL?

    weak var store: HistoryStore?
    weak var appState: AppState?

    var client: HelperClient { HelperClient(token: helperToken) }

    // MARK: - 接入 / 断开

    func connect() async {
        guard connectionState != .connecting, connectionState != .connected else { return }
        connectionState = .connecting
        lastError = nil

        guard let adb = AdbService.url() else {
            connectionState = .error
            lastError = "未找到 adb（请安装 Android platform-tools）"
            return
        }
        adbURL = adb

        let devices = await AdbService.devices(adb: adb)
        guard let device = devices.first else {
            connectionState = .error
            lastError = "未检测到 ADB 设备（USB 连接或无线调试配对）"
            return
        }
        deviceName = device.model
        deviceSerial = device.serial
        // 友好设备名：marketingname 优先（如 "Xiaomi 13 Pro"），model/brand 兜底
        let props = await AdbService.shell(adb: adb, serial: device.serial, command: "getprop")
        deviceName = Self.friendlyDeviceName(props: props, fallback: device.model) ?? device.model

        do {
            try await ensureHelperRunning(adb: adb, serial: device.serial)
        } catch {
            connectionState = .error
            lastError = error.localizedDescription
            return
        }

        if let st = await client.clipboardStatus() {
            lastSeq = st.seq
        }
        connectionState = .connected
        lastError = nil
        NSLog("PinClip.android: 已接入 \(device.model)")

        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    func disconnect() {
        pollTask?.cancel()
        pollTask = nil
        helperProcess?.terminate()
        helperProcess = nil
        connectionState = .idle
        deviceName = ""
    }

    /// App 退出时调用：终止设备端 helper 进程（会话级生命周期）
    func shutdown() {
        pollTask?.cancel()
        pollTask = nil
        helperProcess?.terminate()
        helperProcess = nil
    }

    // MARK: - 长轮询循环（连续两错重建会话）

    private func pollLoop() async {
        var consecutiveErrors = 0
        while connectionState == .connected, !Task.isCancelled {
            do {
                guard let r = await client.waitClipboard(seq: lastSeq, timeoutMs: 25000) else {
                    throw HelperError.transport
                }
                consecutiveErrors = 0
                lastSeq = r.seq
                guard r.changed, let text = r.text, !text.isEmpty else { continue }
                // 暂停记录时，Android 方向同样不入库（双向同步尊重暂停开关）
                guard appState?.settings.paused != true else { continue }
                // 与剪贴板监听同一套隐私过滤（此前手机来的文本绕过了敏感内容检测）
                let settings = appState?.settings ?? AppSettings()
                let source = AppSource(bundleID: "android.sync", name: "Android · \(deviceName)")
                let (ok, _) = PrivacyFilter.shouldRecord(settings: settings, kind: .text, text: text, source: source)
                guard ok else { continue }
                store?.record(text: text, source: source)
                // 日志只记长度，不落剪贴板内容（隐私）
                NSLog("PinClip.android: 手机剪贴板变化 → 已入历史（\(text.count) 字符）")
            } catch is CancellationError {
                return
            } catch {
                consecutiveErrors += 1
                NSLog("PinClip.android: 轮询错误(\(consecutiveErrors)) \(error)")
                if consecutiveErrors >= 2 {
                    // 会话重建：forward 可能失效，重 ping → 重 forward → 必要时重启 helper
                    connectionState = .connecting
                    await reconnectSession()
                    guard connectionState == .connected else {
                        connectionState = .error
                        lastError = "设备连接丢失"
                        return
                    }
                    connectionState = .connected
                    consecutiveErrors = 0
                } else {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
    }

    /// Mac 剪贴板变化 → 推送到 Android 剪贴板（写入方向不受 Android 限制；helper 仅支持文本）
    func pushToAndroid(_ text: String) {
        guard connectionState == .connected,
              appState?.settings.androidSyncEnabled == true,
              !text.isEmpty else { return }
        Task { [client] in
            let ok = await client.clipboardSet(text)
            NSLog("PinClip.android: 推送手机剪贴板 \(ok ? "成功" : "失败")")
        }
    }

    // MARK: - 会话建立 / 重建

    private func ensureHelperRunning(adb: URL, serial: String) async throws {
        let jar = AdbService.helperJarURL()
        guard let jar else {
            throw HelperError.jarMissing
        }
        // 1) push jar 到 PinClip 专属路径（与 app-inspector 的 helper 完全隔离）
        await AdbService.run(adb: adb, args: ["-s", serial, "shell", "mkdir -p /data/local/tmp/pinclip"])
        await AdbService.run(adb: adb, args: ["-s", serial, "push", jar.path, "/data/local/tmp/pinclip/app-inspector-helper.jar"])
        // 2) 清掉旧实例（作用域限定 PinClip 端口，绝不触碰 app-inspector 的 17877 实例）
        await AdbService.run(adb: adb, args: ["-s", serial, "shell", "pkill -f 'Helper --port 17878' || true"])
        try? await Task.sleep(nanoseconds: 300_000_000)
        // 3) 端口转发
        await AdbService.run(adb: adb, args: ["-s", serial, "forward", "tcp:\(HelperClient.defaultPort)", "tcp:\(HelperClient.defaultPort)"])
        // 4) app_process 拉起（前台常驻；App 退出时 terminate）
        let proc = Process()
        proc.executableURL = adb
        proc.arguments = [
            "-s", serial, "shell",
            "CLASSPATH=/data/local/tmp/pinclip/app-inspector-helper.jar app_process / com.appinspector.helper.Helper --port \(HelperClient.defaultPort) --token \(helperToken)",
        ]
        // 管道持续排空（否则输出积到 64KB 会阻塞 helper）
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        drain(pipe: outPipe)
        drain(pipe: errPipe)
        do { try proc.run() } catch {
            throw HelperError.launchFailed(error.localizedDescription)
        }
        helperProcess = proc

        // 5) ping 轮询 ≤ 10s
        for _ in 0..<20 {
            if await client.ping() {
                NSLog("PinClip.android: helper 就绪")
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        throw HelperError.pingTimeout
    }

    /// 后台持续读管道丢弃（防止 64KB 管道缓冲写满阻塞子进程）
    private func drain(pipe: Pipe) {
        Task.detached(priority: .utility) {
            let fh = pipe.fileHandleForReading
            while true {
                let chunk = fh.availableData
                if chunk.isEmpty { break }
            }
        }
    }

    /// 从 getprop 输出解析友好设备名（marketname → model → brand 依次兜底）
    static func friendlyDeviceName(props: String, fallback: String) -> String? {
        for key in ["ro.product.marketname", "ro.product.mod_device", "ro.product.model", "ro.product.brand"] {
            for line in props.split(separator: "\n") {
                guard line.contains("[\(key)]: ["),
                      let range = line.range(of: "]: [")
                else { continue }
                let value = line[range.upperBound...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: "] "))
                if !value.isEmpty {
                    return value
                }
            }
        }
        return fallback.isEmpty ? nil : fallback
    }

    private func reconnectSession() async {
        guard let adb = adbURL, !deviceSerial.isEmpty else {
            // 串口未知（极少见）：直接回退到完整接入
            await connect()
            return
        }
        do {
            try await ensureHelperRunning(adb: adb, serial: deviceSerial)
        } catch {
            NSLog("PinClip.android: 会话重建失败 \(error)")
        }
    }
}

// MARK: - 错误

enum HelperError: LocalizedError {
    case jarMissing
    case pingTimeout
    case launchFailed(String)
    case transport

    var errorDescription: String? {
        switch self {
        case .jarMissing: return "helper jar 资源缺失"
        case .pingTimeout: return "设备端 helper 无响应（超时）"
        case .launchFailed(let reason): return "helper 拉起失败：\(reason)"
        case .transport: return "与设备通信中断"
        }
    }
}
