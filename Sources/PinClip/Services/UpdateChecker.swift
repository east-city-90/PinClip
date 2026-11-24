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
        return Release(tag: tag, url: URL(string: urlStr) ?? releasesURL)
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

    /// 手动「检查更新」：结果无论新旧都 toast 告知；发现新版则打开发布页
    static func checkManual(appState: AppState) async {
        guard let release = await latest() else {
            appState.showToast("检查更新失败（网络不可用？）")
            return
        }
        if isNewer(release.tag, than: currentVersion()) {
            appState.showToast("新版本 \(release.tag) 可用，已打开发布页")
            NSWorkspace.shared.open(release.url)
        } else {
            appState.showToast("已是最新版本 v\(currentVersion())")
        }
    }

    /// 启动后的静默检查：每天至多一次；发现新版只提示不自动打开
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
                appState.showToast("PinClip \(release.tag) 已发布 · 设置→关于 可查看更新")
            }
        }
    }
}
