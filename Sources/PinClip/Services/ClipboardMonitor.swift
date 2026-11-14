import AppKit

/// 剪贴板监听：macOS 无变更通知，标准做法是 500ms 轮询 changeCount（设计方案 §5.3）
@MainActor
final class ClipboardMonitor {
    private var timer: Timer?
    private var lastChangeCount: Int
    private weak var store: HistoryStore?
    private let settingsProvider: () -> AppSettings

    init(store: HistoryStore, settingsProvider: @escaping () -> AppSettings) {
        self.store = store
        self.settingsProvider = settingsProvider
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        // 启动时把当前剪贴板作为第一条入库（「刚才复制过的东西」是核心诉求）
        poll(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.poll() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll(force: Bool = false) {
        let cc = NSPasteboard.general.changeCount
        guard cc != lastChangeCount || force else { return }
        lastChangeCount = cc

        let settings = settingsProvider()
        guard !settings.paused else { return }

        let source = AppSource.current()
        let sourceURL = ClipboardReader.currentSourceURL()
        let content = ClipboardReader.readCurrent()
        guard let store else { return }

        switch content {
        case .text(let text):
            let (ok, _) = PrivacyFilter.shouldRecord(settings: settings, kind: .text, text: text, source: source)
            if ok { store.record(text: text, source: source, sourceURL: sourceURL) }

        case .image(let png, _, _):
            let (ok, _) = PrivacyFilter.shouldRecord(settings: settings, kind: .image, text: nil, source: source)
            if ok { store.recordImage(pngData: png, source: source, kind: .image, sourceURL: sourceURL) }

        case .files(let paths):
            let joined = paths.joined(separator: "\n")
            let (ok, _) = PrivacyFilter.shouldRecord(settings: settings, kind: .files, text: joined, source: source)
            if ok { store.recordFiles(paths: paths, source: source, sourceURL: sourceURL) }

        case .none:
            break
        }
    }
}
