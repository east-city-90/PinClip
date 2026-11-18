import AppKit
import SwiftUI
import Translation

/// 面板视图模型：由 PanelController 持有（CLT 环境无 SwiftUI 宏插件，@State 不可用，
/// 状态统一放 @Observable VM；控件绑定用 Binding(get:set:) 手动构造）
@MainActor
@Observable
final class PanelVM {
    var pinned: [ClipItem] = []
    var items: [ClipItem] = []
    var query = ""
    var filter: HistoryFilter = .all
    var selectedID: Int64?
    var toast: String?
    var reloadTask: Task<Void, Never>?
    var toastClearTask: Task<Void, Never>?
    var observerTokens: [NSObjectProtocol] = []
    /// 右侧详情当前条目的来源图标（App 图标 / favicon，异步加载）
    var detailIcon: NSImage?
    /// 右侧详情大图（ImageIO 降采样，后台解码）
    var detailImage: NSImage?
    /// 列表行缩略图缓存（path → 24px 图，后台解码）
    var thumbImages: [String: NSImage] = [:]
    /// 文本详情的转换结果（工具行处理后的文本；nil = 未转换）
    var detailTransformed: String?
    /// 当前应用的转换名（用于工具行高亮）
    var detailTransformKey: String?
    /// Apple 翻译弹窗展示开关（macOS 15+，系统全权处理语言检测/确认/下载）
    var presentTranslation = false

    weak var store: HistoryStore?
    weak var appState: AppState?

    init(store: HistoryStore, appState: AppState) {
        self.store = store
        self.appState = appState
    }

    /// 展示顺序（置顶在前）用于 ↑↓ 导航
    var orderedItems: [ClipItem] { pinned + items }

    var selectedItem: ClipItem? {
        orderedItems.first { $0.id == selectedID }
    }

    func resetForShow() {
        query = ""
        filter = .all
        reload()
        // 唤起时无条件选中最新一条（用户预期：默认选中最新的）
        selectedID = orderedItems.first?.id
    }

    func reload() {
        guard let store else { return }
        let page = store.page(query: query, kind: filter)
        pinned = page.pinned
        items = page.items
        if selectedID == nil || !orderedItems.contains(where: { $0.id == selectedID }) {
            selectedID = orderedItems.first?.id
        }
    }

    func reloadPreservingSelection() {
        let keep = selectedID
        reload()
        selectedID = keep
    }

    func debounceReload() {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            self?.reload()
        }
    }

    func moveSelection(_ delta: Int) {
        let list = orderedItems
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == selectedID } ?? 0
        let next = max(0, min(list.count - 1, current + delta))
        selectedID = list[next].id
    }

    func showToast(_ text: String) {
        toast = text
        toastClearTask?.cancel()
        toastClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self?.toast == text { self?.toast = nil }
        }
    }
}

/// 历史面板主视图：左列表（摘要）+ 右详情（内容优先，元信息在下），顶部搜索过滤，底部快捷键条
struct HistoryPanelView: View {
    let vm: PanelVM
    let appState: AppState
    let actions: any PanelActions

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if appState.paused { pausedBanner }
            Divider().overlay(Color(nsColor: .separatorColor))
            HStack(spacing: 0) {
                masterList
                    .frame(width: 264)
                Divider().overlay(Color(nsColor: .separatorColor))
                DetailPane(item: vm.selectedItem, appState: appState, actions: actions, vm: vm)
            }
            footerHints
        }
        .overlay(alignment: .bottom) {
            if let toast = vm.toast {
                ToastView(text: toast)
                    .padding(.bottom, 44)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: vm.toast)
        .onAppear {
            vm.reload()
            KeyboardRouter.shared.register { [vm] event in
                handleKey(event, vm: vm)
            }
            observeNotifications()
        }
        .onDisappear {
            KeyboardRouter.shared.unregister()
            vm.observerTokens.forEach { NotificationCenter.default.removeObserver($0) }
            vm.observerTokens.removeAll()
        }
        .onChange(of: vm.store?.revision ?? 0) { _, _ in vm.reloadPreservingSelection() }
        .onChange(of: appState.toastText) { _, newValue in
            guard let newValue else { return }
            vm.showToast(newValue)
        }
    }

    // MARK: 顶栏（44px：搜索 / 分段过滤 / 暂停 / 设置）

    private var topBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                TextField("搜索剪贴板…", text: Binding(
                    get: { vm.query },
                    set: {
                        vm.query = $0
                        vm.debounceReload()
                    }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))

            // 原生分段控件：自动继承系统最新观感（含 Liquid Glass），tint 靛蓝
            Picker("", selection: Binding(
                get: { vm.filter },
                set: {
                    vm.filter = $0
                    vm.reload()
                }
            )) {
                ForEach(HistoryFilter.allCases, id: \.self) { f in
                    Text(f.label).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private var pausedBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.orange)
            Text("记录已暂停，此期间的复制不会被保存")
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(Color.orange.opacity(0.10))
    }

    // MARK: 左侧：摘要列表（ScrollView + 显式手势：List 的 selection 会与行上双击手势冲突导致单击无响应）

    @ViewBuilder
    private var masterList: some View {
        if vm.orderedItems.isEmpty {
            emptyListState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if !vm.pinned.isEmpty {
                            SectionHeader(title: "★ 置顶")
                                .id("list-top")
                            ForEach(vm.pinned) { item in
                                compactRow(for: item)
                            }
                        } else {
                            SectionHeader(title: listSectionTitle)
                                .id("list-top")
                        }
                        ForEach(vm.items) { item in
                            compactRow(for: item)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .scrollIndicators(.never)
                .onReceive(NotificationCenter.default.publisher(for: .pinclipPanelShown)) { _ in
                    // 唤起时回到列表顶部（最新条目在顶部）
                    proxy.scrollTo("list-top", anchor: .top)
                }
                .onChange(of: vm.selectedID) { _, newID in
                    // 键盘 ↑↓ 导航时保持选中行可见
                    guard let id = newID else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    /// 列表分组标题（今天/昨天/本周/更早）
    private var listSectionTitle: String {
        vm.items.first.map { Theme.groupLabel(for: $0.createdAt) } ?? "今天"
    }

    /// 紧凑摘要行：单行显示（预览 + 右侧时间），图片行带小缩略图
    @ViewBuilder
    private func compactRow(for item: ClipItem) -> some View {
        let selected = vm.selectedID == item.id
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1)
                .fill(selected ? Theme.accent : Color.clear)
                .frame(width: 2, height: 22)
            if item.kind == .image || item.kind == .screenshot {
                rowLeading(for: item, thumb: item.thumbPath.flatMap { vm.thumbImages[$0] })
            }
            previewLine(for: item)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if item.pinned { PinBadge() }
            Text(Theme.timeString(item.createdAt))
                .font(.system(size: 10))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Theme.cardFillHover : Color.clear)
        )
        .contentShape(Rectangle())
        .task(id: item.id) {
            // 缩略图后台解码（64px ImageIO 降采样 + NSCache），行渲染零解码
            if let path = item.thumbPath, vm.thumbImages[path] == nil {
                vm.thumbImages[path] = await ImageCache.loadThumb(path: path)
            }
        }
        // 点已选中的行 = 直接粘贴；点未选中的行 = 选中查看详情（再点一次或回车即粘贴）
        .onTapGesture {
            if vm.selectedID == item.id {
                actions.activate(item, paste: appState.settings.autoPaste)
            } else {
                vm.selectedID = item.id
            }
        }
        .contextMenu { contextActions(for: item) }
    }

    /// 图片行的真实缩略图（后台解码缓存；文字/文件行不显示图标）
    @ViewBuilder
    private func rowLeading(for item: ClipItem, thumb: NSImage?) -> some View {
        if let thumb {
            Image(nsImage: thumb)
                .resizable()
                .scaledToFill()
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
        } else {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(0.06))
                .frame(width: 24, height: 24)
        }
    }

    @ViewBuilder
    private func previewLine(for item: ClipItem) -> some View {
        switch item.kind {
        case .text:
            Text(item.textContent?.replacingOccurrences(of: "\n", with: " ") ?? "")
        case .image, .screenshot:
            Text(item.kind == .screenshot ? "截图" : "图片")
        case .files:
            Text(item.textContent?.split(separator: "\n").first.map(String.init) ?? "文件")
        }
    }

    private var emptyListState: some View {
        VStack(spacing: 8) {
            Spacer()
            if vm.query.isEmpty {
                Image(systemName: "clipboard")
                    .font(.system(size: 30))
                    .foregroundStyle(Color(nsColor: .quaternaryLabelColor))
                Text("剪贴板空空如也")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                Text("复制任何内容，或按 ⌥A 截一张图")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 24))
                    .foregroundStyle(Color(nsColor: .quaternaryLabelColor))
                Text("没有匹配的记录")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 底部快捷键条（28px）

    private var footerHints: some View {
        HStack(spacing: 10) {
            Text("↑↓ 选择").keyStyle()
            Text("⏎ 粘贴").keyStyle()
            Text("双击粘贴").keyStyle()
            Text("⌘⏎ 复制").keyStyle()
            Text("⌫ 删除").keyStyle()
            Spacer()
            Text("⌘1-9 置顶粘贴").keyStyle()
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.06))
    }

    // MARK: 右键菜单

    @ViewBuilder
    private func contextActions(for item: ClipItem) -> some View {
        Button("粘贴") { actions.activate(item, paste: appState.settings.autoPaste) }
        Button("仅复制") { actions.activate(item, paste: false) }
        if item.kind == .text {
            Button("复制为纯文本") { actions.copyPlain(item) }
        }
        Divider()
        Button(item.pinned ? "取消置顶" : "置顶") { actions.togglePin(item) }
        if item.kind == .image || item.kind == .screenshot {
            Button("贴图") { _ = actions.pinToScreen(item) }
        }
        Divider()
        Button("删除", role: .destructive) { actions.delete(item) }
    }

    // MARK: 通知订阅

    private func observeNotifications() {
        let center = NotificationCenter.default
        vm.observerTokens.append(center.addObserver(forName: .pinclipHistoryChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in vm.reloadPreservingSelection() }
        })
        vm.observerTokens.append(center.addObserver(forName: .pinclipPanelShown, object: nil, queue: .main) { _ in
            Task { @MainActor in
                vm.resetForShow()
                searchFocused = true
            }
        })
        vm.observerTokens.append(center.addObserver(forName: .pinclipToast, object: nil, queue: .main) { note in
            Task { @MainActor in
                if let text = note.userInfo?["text"] as? String { vm.showToast(text) }
            }
        })
    }

    // MARK: 键盘流（非激活面板：窗口级 keyDown 路由）

    private func handleKey(_ event: NSEvent, vm: PanelVM) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 126: // ↑
            vm.moveSelection(-1); return true
        case 125: // ↓
            vm.moveSelection(1); return true
        case 36, 76: // Enter
            if flags.contains(.command) {
                if let item = vm.selectedItem { actions.activate(item, paste: false) }
            } else if let item = vm.selectedItem {
                actions.activate(item, paste: appState.settings.autoPaste)
            }
            return true
        case 51: // ⌫
            if let item = vm.selectedItem { actions.delete(item) }
            return true
        case 53: // Esc
            actions.hidePanel()
            return true
        default:
            if flags.contains(.command), !flags.contains(.shift), !flags.contains(.option), !flags.contains(.control),
               let ch = event.charactersIgnoringModifiers, let n = Int(ch), n >= 1, n <= 9,
               vm.pinned.indices.contains(n - 1) {
                actions.activate(vm.pinned[n - 1], paste: appState.settings.autoPaste)
                return true
            }
            if flags.contains(.command), event.charactersIgnoringModifiers == "f" {
                searchFocused = true
                return true
            }
            return false
        }
    }
}

// MARK: - 右侧详情：内容优先，操作按钮与元信息在底部

/// 详情面板：主体内容（大图/全文/文件清单）占据上部主要空间，底部为操作按钮 + 元信息
struct DetailPane: View {
    let item: ClipItem?
    let appState: AppState
    let actions: any PanelActions
    let vm: PanelVM

    var body: some View {
        Group {
            if let item {
                VStack(spacing: 0) {
                    content(for: item)          // 详情优先展示
                    Divider().overlay(Color(nsColor: .separatorColor))
                    footer(for: item)           // 操作按钮 + 元信息
                }
                .task(id: item.id) {
                    vm.detailIcon = nil
                    vm.detailTransformed = nil
                    vm.detailTransformKey = nil
                    vm.detailImage = nil
                    // 大图优先（降采样后台解码），再补来源图标
                    if item.kind == .image || item.kind == .screenshot, let path = item.mediaPath {
                        vm.detailImage = await ImageCache.loadDetail(path: path)
                    }
                    vm.detailIcon = await FaviconService.icon(
                        for: item,
                        allowNetwork: appState.settings.webFaviconEnabled
                    )
                }
                .modifier(TranslationPresentationModifier(
                    isPresented: Binding(
                        get: { vm.presentTranslation },
                        set: { vm.presentTranslation = $0 }
                    ),
                    text: vm.detailTransformed ?? item.textContent ?? ""
                ))
            } else {
                emptyDetail
            }
        }
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.05))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 底部：操作按钮 + 元信息

    private func footer(for item: ClipItem) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                detailButton("粘贴", symbol: "rectangle.on.rectangle") {
                    pasteDisplayed(item)
                }
                detailButton("复制", symbol: "doc.on.doc") {
                    copyDisplayed(item)
                }
                if item.kind == .text {
                    detailButton("纯文本", symbol: "text.justify") {
                        actions.copyPlain(item)
                    }
                }
                detailButton(item.pinned ? "取消置顶" : "置顶", symbol: "pin") {
                    actions.togglePin(item)
                }
                if item.kind == .image || item.kind == .screenshot {
                    detailButton("贴图", symbol: "pin.fill") {
                        _ = actions.pinToScreen(item)
                    }
                }
                if item.kind == .image || item.kind == .screenshot, let path = item.mediaPath {
                    detailButton("访达", symbol: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
                Spacer(minLength: 0)
                detailButton("删除", symbol: "trash", role: .destructive) {
                    actions.delete(item)
                }
            }
            HStack(spacing: 6) {
                SourceIconView(image: vm.detailIcon, fallbackText: String(Theme.appName(item).prefix(1)))
                MetaLine(parts: [
                    Theme.appName(item),
                    FaviconService.hostDisplay(item.sourceURL),
                    Theme.sizeDescription(item),
                    Theme.fullString(item.createdAt),
                    item.hitCount > 1 ? "×\(item.hitCount)" : nil,
                    item.pinned ? "📌 已置顶" : nil,
                ])
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private func detailButton(_ title: String, symbol: String, role: ButtonRole? = nil,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Color(nsColor: .systemRed) : Color(nsColor: .labelColor))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(role == .destructive ? Color(nsColor: .systemRed).opacity(0.10) : Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
        )
        .help(title)
    }

    // MARK: 内容区（详情主体）

    @ViewBuilder
    private func content(for item: ClipItem) -> some View {
        switch item.kind {
        case .image, .screenshot:
            imageContent(for: item)
        case .text:
            textContent(for: item)
        case .files:
            filesContent(for: item)
        }
    }

    /// 图片：撑满可用空间的大图预览（后台降采样解码，加载中显示占位）
    @ViewBuilder
    private func imageContent(for item: ClipItem) -> some View {
        if let path = item.mediaPath {
            if let image = vm.detailImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.05))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(ProgressView())
                    .padding(12)
            }
        } else {
            Image(systemName: "photo")
                .font(.system(size: 40))
                .foregroundStyle(Color(nsColor: .quaternaryLabelColor))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 文本：工具行（一键处理）+ 全文可选复制
    private func textContent(for item: ClipItem) -> some View {
        VStack(spacing: 0) {
            toolRow(for: item)
            ScrollView {
                Text(vm.detailTransformed ?? item.textContent ?? "")
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .scrollIndicators(.never)
        }
    }

    /// 文本处理工具行（高频：去换行/去空格/JSON 美化/URL 解码/时间戳/翻译）
    private func toolRow(for item: ClipItem) -> some View {
        HStack(spacing: 6) {
            ForEach([("去换行", "newlines"), ("去空格", "spaces"), ("JSON 美化", "json"),
                     ("URL 解码", "urldecode"), ("时间戳→日期", "timestamp"),
                     ("翻译", "translation")], id: \.1) { pair in
                let applied = vm.detailTransformKey == pair.1
                Button {
                    applyTransform(pair.1, item)
                } label: {
                    Text(pair.0)
                        .font(.system(size: 11, weight: applied ? .semibold : .regular))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .foregroundStyle(applied ? Theme.accent : Color(nsColor: .labelColor))
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(applied ? Theme.accent.opacity(0.14) : Theme.cardFill)
                )
            }
            if vm.detailTransformed != nil {
                Button {
                    vm.detailTransformed = nil
                    vm.detailTransformKey = nil
                } label: {
                    Text("还原")
                        .font(.system(size: 11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 6))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    /// 应用文本转换：就地显示 + 自动复制处理结果
    private func applyTransform(_ key: String, _ item: ClipItem) {
        let original = item.textContent ?? ""
        var result: String?
        switch key {
        case "translation":
            // Apple 系统翻译：智能目标语言
            // 文本含中文 → 译英文（中英互译主场景）；纯西文 → 译系统首选语言
            guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 else {
                appState.showToast("翻译需要 macOS 15 及以上版本")
                return
            }
            if #available(macOS 15.0, *) {
                // 系统翻译弹窗：语言检测/确认/资源下载全部由系统处理（无边框面板上 sheet 不可用）
                vm.presentTranslation = true
            }
            return
        case "newlines":
            var s = original.replacingOccurrences(of: "\r", with: "")
            s = s.replacingOccurrences(of: "\n", with: " ")
            while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
            result = s.trimmingCharacters(in: .whitespaces)
        case "spaces":
            result = original
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "\t", with: "")
        case "json":
            if let data = original.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes]),
               let s = String(data: pretty, encoding: .utf8) {
                result = s
            } else {
                appState.showToast("不是有效的 JSON")
                return
            }
        case "urldecode":
            if let s = original.removingPercentEncoding {
                result = s
            } else {
                appState.showToast("不是有效的 URL 编码")
                return
            }
        case "timestamp":
            let digits = original.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !digits.isEmpty, digits.allSatisfy({ $0.isNumber }) else {
                appState.showToast("内容不是纯数字时间戳")
                return
            }
            let interval: TimeInterval
            if digits.count >= 13 {
                interval = Double(digits.prefix(13))! / 1000
            } else {
                interval = Double(digits.prefix(10))!
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            result = formatter.string(from: Date(timeIntervalSince1970: interval))
        default:
            return
        }
        guard let result else { return }
        vm.detailTransformed = result
        vm.detailTransformKey = key
        ClipboardWriter.writeText(result)
        vm.showToast("已处理并复制结果")
    }

    /// 复制按钮：文本有转换结果时复制转换后的文本（面板保持打开）
    private func copyDisplayed(_ item: ClipItem) {
        if item.kind == .text, let t = vm.detailTransformed {
            ClipboardWriter.writeText(t)
            appState.showToast("已复制处理结果")
        } else {
            actions.activate(item, paste: false)
        }
    }

    /// 粘贴按钮：文本有转换结果时直接粘贴转换后的文本
    private func pasteDisplayed(_ item: ClipItem) {
        if item.kind == .text, let t = vm.detailTransformed {
            ClipboardWriter.writeText(t)
            actions.hidePanel()
            let settings = appState.settings
            if settings.autoPaste, AutoPaste.isProcessTrusted(prompt: false) {
                AutoPaste.postCommandV(delayMs: settings.autoPasteDelayMs)
            } else {
                appState.showToast("已复制处理结果")
            }
        } else {
            actions.activate(item, paste: appState.settings.autoPaste)
        }
    }

    /// 文件：路径清单，点击在访达中显示
    private func filesContent(for item: ClipItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                let paths = item.textContent?.split(separator: "\n").map(String.init) ?? []
                ForEach(paths, id: \.self) { path in
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc")
                                .font(.system(size: 11))
                                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            Text((path as NSString).lastPathComponent)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text("在访达中显示")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.accent)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
                Text("点击条目在访达中显示文件")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }

    private var emptyDetail: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(Color(nsColor: .quaternaryLabelColor))
            Text("选择左侧条目查看详情")
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension Text {
    func keyStyle() -> some View {
        font(.system(size: 10))
            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
    }
}

/// Apple 翻译弹窗（macOS 14.4+ 可用性门控；语言检测/确认/下载全部由系统处理）
struct TranslationPresentationModifier: ViewModifier {
    let isPresented: Binding<Bool>
    let text: String

    func body(content: Content) -> some View {
        if #available(macOS 14.4, *) {
            content.translationPresentation(isPresented: isPresented, text: text)
        } else {
            content
        }
    }
}

/// 窗口级键盘路由：把面板窗口的 keyDown 交给处理器（面板为 key window 时）
@MainActor
final class KeyboardRouter {
    static let shared = KeyboardRouter()
    private var handler: ((NSEvent) -> Bool)?
    private var monitor: Any?

    func register(handler: @escaping (NSEvent) -> Bool) {
        self.handler = handler
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, NSApp.keyWindow is PanelPanel else { return event }
                return self.handler?(event) == true ? nil : event
            }
        }
    }

    func unregister() {
        handler = nil
    }
}
