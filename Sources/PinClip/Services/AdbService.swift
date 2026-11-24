import Foundation

/// adb 二进制定位与设备枚举（v0.1.3 Android 剪贴板同步）
/// 所有 adb 子进程都在后台串行队列执行（带超时看门狗），绝不阻塞主线程。
enum AdbService {

    static func url() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = [
            URL(fileURLWithPath: "/opt/homebrew/bin/adb"),
            URL(fileURLWithPath: "/usr/local/bin/adb"),
            URL(fileURLWithPath: NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb"),
        ]
        let pathDirs = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        for d in pathDirs {
            candidates.append(URL(fileURLWithPath: d).appendingPathComponent("adb"))
        }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    struct Device {
        let serial: String
        let model: String
        let state: String
    }

    /// 已连接且处于 device 状态的设备列表（异步，后台队列执行）
    static func devices(adb: URL) async -> [Device] {
        let out = await run(adb: adb, args: ["devices", "-l"])
        var result: [Device] = []
        for line in out.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 3 else { continue }
            let serial = cols[0]
            let state = cols[1]
            guard state == "device" else { continue }
            var model = serial
            for c in cols.dropFirst(2) where c.hasPrefix("model:") {
                model = String(c.dropFirst(6))
            }
            result.append(Device(serial: serial, model: model, state: state))
        }
        return result
    }

    /// Helper jar 在宿主资源中的位置（release .app / swift run 两种布局 + 源码树兜底）
    static func helperJarURL() -> URL? {
        let rel = "AndroidSync/app-inspector-helper.jar"
        let fm = FileManager.default
        var candidates: [URL] = []
        if let r = Bundle.main.resourceURL {
            candidates.append(r.appendingPathComponent("Resources/" + rel))
            candidates.append(r.appendingPathComponent(rel))
        }
        if let r = Bundle.module.resourceURL {
            candidates.append(r.appendingPathComponent("Resources/" + rel))
            candidates.append(r.appendingPathComponent(rel))
        }
        // swift run 源码树兜底
        candidates.append(URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Services
            .deletingLastPathComponent()      // PinClip
            .appendingPathComponent("Resources/" + rel))
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    /// 异步执行 adb 命令（后台串行队列 + 超时看门狗），返回 stdout（出错/超时返回空串）
    static func run(adb: URL, args: [String], timeout: TimeInterval = 10) async -> String {
        await withCheckedContinuation { cont in
            queue.async {
                cont.resume(returning: runBlocking(adb: adb, args: args, timeout: timeout))
            }
        }
    }

    /// 设备端 shell 命令（异步）
    static func shell(adb: URL, serial: String, command: String, timeout: TimeInterval = 10) async -> String {
        await run(adb: adb, args: ["-s", serial, "shell", command], timeout: timeout)
    }

    // MARK: - 内部（仅在 queue 上运行）

    private static let queue = DispatchQueue(label: "pinclip.adb", qos: .userInitiated)

    /// 阻塞执行；看门狗超时 terminate 进程（此前 adb 挂起会永久卡住调用方）
    private static func runBlocking(adb: URL, args: [String], timeout: TimeInterval) -> String {
        let p = Process()
        p.executableURL = adb
        p.arguments = args
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return "" }
        // 看门狗：超时仍未退出则 terminate（读管道随即返回 EOF）
        let watchdog = DispatchWorkItem { [weak p] in
            guard let p, p.isRunning else { return }
            p.terminate()
        }
        queue.asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
