import AppKit
import Foundation

/// 更新检查（GitHub Releases；无遥测——只在用户开启时请求 releases/latest）
@MainActor
enum UpdateChecker {

    static let releasesURL = URL(string: "https://github.com/east-city-90/PinClip/releases/latest")!
    private static let apiURL = URL(string: "https://api.github.com/repos/east-city-90/PinClip/releases/latest")!

    static func currentVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    struct Release {
        let tag: String
        let url: URL
        /// zip 资产直链（releases/latest 的 assets 里取）
        let downloadURL: URL?
    }

    static func latest() async -> Release? {
        var req = URLRequest(url: apiURL, timeoutInterval: 8)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String
        else { return nil }
        let urlStr = (obj["html_url"] as? String) ?? releasesURL.absoluteString
        let downloadURL = ((obj["assets"] as? [[String: Any]]) ?? [])
            .compactMap { asset -> URL? in
                guard let name = asset["name"] as? String, name.hasSuffix(".zip"),
                      let link = asset["browser_download_url"] as? String
                else { return nil }
                return URL(string: link)
            }
            .first
        return Release(tag: tag, url: URL(string: urlStr) ?? releasesURL, downloadURL: downloadURL)
    }

    /// 数值版本比较（忽略前缀 v；段数不同按 0 补齐）
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let c = candidate.split(separator: ".").map { Int($0.trimmingPrefix("v")) ?? 0 }
        let cur = current.split(separator: ".").map { Int($0.trimmingPrefix("v")) ?? 0 }
        let n = max(c.count, cur.count)
        let cc = c + Array(repeating: 0, count: n - c.count)
        let cu = cur + Array(repeating: 0, count: n - cur.count)
        for i in 0..<n where cc[i] != cu[i] {
            return cc[i] > cu[i]
        }
        return false
    }

    /// 手动「检查更新」：发现新版 → 全自动更新（下载 → 安装 → 重启）
    static func checkManual(appState: AppState) async {
        guard let release = await latest() else {
            appState.showToast("检查更新失败（网络不可用？）")
            return
        }
        if isNewer(release.tag, than: currentVersion()) {
            await performAutoUpdate(release, appState: appState)
        } else {
            appState.showToast("已是最新版本 v\(currentVersion())")
        }
    }

    /// 启动后的静默检查（每天至多一次）：发现新版直接全自动更新
    static func autoCheckIfNeeded(appState: AppState) {
        guard appState.settings.checkUpdates else { return }
        let now = Date().timeIntervalSince1970
        guard now - appState.settings.lastUpdateCheck > 24 * 3600 else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000) // 启动后稍等，避免抢网络/焦点
            guard !Task.isCancelled else { return }
            guard let release = await latest() else { return }
            appState.updateSettings { $0.lastUpdateCheck = Date().timeIntervalSince1970 }
            if isNewer(release.tag, than: currentVersion()) {
                await performAutoUpdate(release, appState: appState)
            }
        }
    }

    /// 全自动更新：下载 zip 到临时目录 → 解压 → 校验签名 → 独立安装脚本
    /// （等本进程退出 → 旧版移走 → 新版就位，失败回滚）→ open 重启。
    /// 新旧包同为 "PinClip Dev" 签名，TCC 授权（屏幕录制等）自动保留。
    static func performAutoUpdate(_ release: Release, appState: AppState) async {
        let fm = FileManager.default
        let bundlePath = Bundle.main.bundlePath
        // 仅支持 .app bundle 运行形态（swift run 裸二进制无法自我替换）
        guard bundlePath.hasSuffix(".app"), fm.fileExists(atPath: bundlePath) else {
            appState.showToast("新版本 \(release.tag) 可用（开发形态运行，请手动更新）")
            NSWorkspace.shared.open(release.url)
            return
        }
        guard let downloadURL = release.downloadURL else {
            // Release 没挂 zip 资产（异常情况）：回退打开发布页
            appState.showToast("新版本 \(release.tag) 发布页")
            NSWorkspace.shared.open(release.url)
            return
        }

        let workDir = fm.temporaryDirectory
            .appendingPathComponent("PinClipUpdate-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        do {
            // 1) 下载
            appState.showToast("新版本 \(release.tag) · 正在下载…")
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
            let zipURL = workDir.appendingPathComponent("update.zip")
            let (tmpURL, response) = try await URLSession.shared.download(from: downloadURL)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw URLError(.badServerResponse)
            }
            try fm.moveItem(at: tmpURL, to: zipURL)

            // 2) 解压
            appState.showToast("新版本 \(release.tag) · 正在安装…")
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", zipURL.path, workDir.path]
            unzip.standardOutput = FileHandle.nullDevice
            unzip.standardError = FileHandle.nullDevice
            try unzip.run()
            unzip.waitUntilExit()
            guard unzip.terminationStatus == 0 else {
                throw URLError(.cannotDecodeContentData)
            }
            let newApp = workDir.appendingPathComponent("PinClip.app")
            guard fm.fileExists(atPath: newApp.appendingPathComponent("Contents/MacOS/PinClip").path) else {
                throw URLError(.cannotDecodeContentData)
            }

            // 3) 签名完整性校验（防损坏/篡改的半包）
            let codesign = Process()
            codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            codesign.arguments = ["--verify", "--strict", newApp.path]
            codesign.standardOutput = FileHandle.nullDevice
            codesign.standardError = FileHandle.nullDevice
            try codesign.run()
            codesign.waitUntilExit()
            guard codesign.terminationStatus == 0 else {
                throw URLError(.badServerResponse)
            }

            // 4) 独立安装脚本：app 退出后由 launchd 收养继续执行。
            //    旧版先 mv 挪走（失败即中止）、新版 cp 到位、成功后清理并重启；cp 失败则回滚旧版。
            let scriptPath = workDir.appendingPathComponent("install-and-relaunch.sh")
            let script = """
            #!/bin/bash
            TARGET=\(bundlePath.shellQuoted)
            NEW=\(newApp.path.shellQuoted)
            WORK=\(workDir.path.shellQuoted)
            # 等旧进程退出（≤10s）
            for i in $(seq 1 40); do pgrep -x PinClip >/dev/null 2>&1 || break; sleep 0.25; done
            if mv "$TARGET" "$TARGET.updating-old"; then
                if cp -R "$NEW" "$TARGET"; then
                    rm -rf "$TARGET.updating-old" "$WORK"
                    open "$TARGET"
                    exit 0
                fi
                # 新版就位失败：回滚旧版
                mv "$TARGET.updating-old" "$TARGET"
            fi
            rm -rf "$WORK"
            """
            try script.write(to: scriptPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
            let installer = Process()
            installer.executableURL = URL(fileURLWithPath: "/bin/bash")
            installer.arguments = [scriptPath.path]
            installer.standardOutput = FileHandle.nullDevice
            installer.standardError = FileHandle.nullDevice
            try installer.run()

            appState.showToast("新版本 \(release.tag) 就绪，正在重启…")
            try? await Task.sleep(nanoseconds: 800_000_000) // 给 toast 一点显示时间
            NSApp.terminate(nil) // 走 applicationWillTerminate 的保存逻辑（设置/贴图状态/同步停机）
        } catch {
            appState.showToast("自动更新失败：\(error.localizedDescription)")
            try? fm.removeItem(at: workDir)
        }
    }
}

extension String {
    /// shell 单引号转义（安装脚本路径用）：foo'bar → 'foo'\''bar'
    var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
