import AppKit
import SwiftUI
import Translation

/// 面板视图模型（@Observable VM 惯例：控件绑定用 Binding(get:set:) 手动构造）
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
    /// 列表行缩略图缓存（path → 64px 图，后台解码）
    var thumbImages: [String: NSImage] = [:]
    /// 文本详情的转换结果（工具行处理后的文本；nil = 未转换）
    var detailTransformed: String?
    /// 当前应用的转换名（用于工具行高亮）
    var detailTransformKey: String?
    /// Apple 翻译弹窗展示开关（系统全权处理语言检测/确认/下载）
    var presentTranslation = false
    /// 分页：列表末尾还有更早条目 / 正在加载
    var hasMore = false
    var loadingMore = false

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
        hasMore = page.hasMore
        loadingMore = false
        if selectedID == nil || !orderedItems.contains(where: { $0.id == selectedID }) {
            selectedID = orderedItems.first?.id
        }
    }

    func reloadPreservingSelection() {
        let keep = selectedID
        reload()
        selectedID = keep
    }

    /// 滚动到底部时增量加载更早条目
    func loadMore() {
        guard hasMore, !loadingMore, let store else { return }
        loadingMore = true
        let page = store.page(query: query, kind: filter, offset: items.count)
        items += page.items
        hasMore = page.hasMore
        loadingMore = false
    }

    func debounceReload() {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            // 注意：try? 会吞掉取消错误，必须显式检查——否则防抖失效（每个按键都触发重载）
            guard !Task.isCancelled else { return }
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

/// 历史面板主视图：左列表（摘要）+ 右详情（内容优先），顶部搜索过滤，底部快捷键条
struct HistoryPanelView: View {
    let vm: PanelVM
    let appState: AppState
    let actions: any PanelActions

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if appState.paused { pausedBanner }
            Divider().overlay(Theme.line)
            HStack(spacing: 0) {
                masterList
                    .frame(width: 264)
                Divider().overlay(Theme.line)
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

    // MARK: 顶栏（44px：搜索 / 分段过滤）

    private var topBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
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
                .onSubmit { vm.reload() }
                if !vm.query.isEmpty {
                    Button {
                        vm.query = ""
                        vm.debounceReload()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.faint)
                    }
                    .buttonStyle(.plain)
                    .help("清除搜索")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Theme.pill, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(searchFocused ? Theme.accent.opacity(0.7) : Theme.line,
                            lineWidth: searchFocused ? 1 : 0.5)
            )

            // 原生分段控件：自动继承系统最新观感（含 Liquid Glass），tint 跟随面板根视图（magpie 靛蓝）
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
                .foregroundStyle(Theme.amber)
            Text("记录已暂停，此期间的复制不会被保存")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(Theme.amberSoft)
    }

    // MARK: 左侧：摘要列表（ScrollView + 显式手势；List 的 selection 会与行手势冲突）

    /// 列表行模型：分组微标签 / 条目行
    private struct ListRow: Identifiable {
        let id: String
        let header: String?
        let item: ClipItem?
    }

    private var listRows: [ListRow] {
        var rows: [ListRow] = []
        if !vm.pinned.isEmpty {
            rows.append(ListRow(id: "hdr-pinned", header: "★ 置顶", item: nil))
            for item in vm.pinned {
                rows.append(ListRow(id: "p-\(item.id)", header: nil, item: item))
            }
        }
        var lastLabel: String?
        for (idx, item) in vm.items.enumerated() {
            let label = Theme.groupLabel(for: item.createdAt)
            if label != lastLabel {
                rows.append(ListRow(id: "hdr-\(idx)-\(label)", header: label, item: nil))
                lastLabel = label
            }
            rows.append(ListRow(id: "i-\(item.id)", header: nil, item: item))
        }
        return rows
    }

    @ViewBuilder
    private var masterList: some View {
        if vm.orderedItems.isEmpty {
            emptyListState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        Color.clear.frame(height: 0).id("list-top")
                        ForEach(listRows) { row in
                            if let header = row.header {
                                SectionHeader(title: header)
                            } else if let item = row.item {
                                CompactRow(vm: vm, appState: appState, actions: actions, item: item)
                            }
                        }
                        if vm.hasMore {
                            HStack {
                                Spacer()
                                if vm.loadingMore {
                                    ProgressView().controlSize(.small)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 6)
                            .onAppear { vm.loadMore() }
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

    private var emptyListState: some View {
        VStack(spacing: 8) {
            Spacer()
            if vm.query.isEmpty {
                Image(systemName: "clipboard")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.faint)
                Text("剪贴板空空如也")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.muted)
                Text("复制任何内容，或按 ⌥A 截一张图")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.faint)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 24))
                    .foregroundStyle(Theme.faint)
                Text("没有匹配的记录")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
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
            Text("⌘⏎ 复制").keyStyle()
            Text("⌫ 删除").keyStyle()
            Spacer()
            Text("⌘1-9 置顶粘贴").keyStyle()
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(Theme.card2)
    }

    // MARK: 右键菜单

    @ViewBuilder
    private func contextActions(for item: ClipItem) -> some View {
        Button("粘贴") { actions.activate(item, paste: appState.settings.autoPaste) }
        Button("仅复制") { actions.activate(item, paste: false) }
        if item.kind == .text {
            Button("复制为纯文本") { actions.copyPlain(item) }
        }
        if item.isVisual {
            Button("标注") { actions.annotate(item) }
        }
        Divider()
        Button(item.pinned ? "取消置顶" : "置顶") { actions.togglePin(item) }
        if item.isVisual {
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

        // 搜索框聚焦时输入优先：字符/⌫ 透传给输入框；↑↓ 保持列表导航；⏎ 粘贴；Esc 先清空搜索
        if searchFocused {
            switch event.keyCode {
            case 126: // ↑ 列表导航
                vm.moveSelection(-1); return true
            case 125: // ↓ 列表导航
                vm.moveSelection(1); return true
            case 36, 76: // ⏎ 粘贴选中项
                if flags.contains(.command) {
                    if let item = vm.selectedItem { actions.activate(item, paste: false) }
                } else if let item = vm.selectedItem {
                    actions.activate(item, paste: appState.settings.autoPaste)
                }
                return true
            case 53: // Esc：有搜索词先清空搜索，无则收起面板
                if !vm.query.isEmpty {
                    vm.query = ""
                    vm.debounceReload()
                } else {
                    actions.hidePanel()
                }
                return true
            case 51: // ⌫ 透传：删除输入框中的字符
                return false
            default:
                if flags.contains(.command), !flags.contains(.shift), !flags.contains(.option), !flags.contains(.control),
                   let ch = event.charactersIgnoringModifiers, let n = Int(ch), n >= 1, n <= 9,
                   vm.pinned.indices.contains(n - 1) {
                    actions.activate(vm.pinned[n - 1], paste: appState.settings.autoPaste)
                    return true
                }
                return false // 其余按键（字符等）透传给输入框
            }
        }

        // 列表导航模式（搜索框未聚焦）
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

// MARK: - 列表行（悬停 pill / 选中靛蓝条 / 等宽时间）

private struct CompactRow: View {
    let vm: PanelVM
    let appState: AppState
    let actions: any PanelActions
    let item: ClipItem

    @State private var hovering = false

    private var selected: Bool { vm.selectedID == item.id }

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1)
                .fill(selected ? Theme.accent : Color.clear)
                .frame(width: 2, height: 22)
            if item.isVisual {
                rowLeading
            }
            previewLine
                .font(.system(size: 12))
                .foregroundStyle(selected ? Theme.fg : Theme.fg2)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if item.pinned { PinBadge() }
            Text(Theme.listTime(item.createdAt))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(hovering || selected ? Theme.muted : Theme.faint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Theme.sel : (hovering ? Theme.pill : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .task(id: item.id) {
            // 缩略图后台解码（64px ImageIO 降采样 + NSCache），行渲染零解码
            if let path = item.displayImagePath, vm.thumbImages[path] == nil {
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
        .contextMenu { contextActions() }
    }

    /// 图片行缩略图（图片/截图/单个图片文件统一走真实缩略图）
    @ViewBuilder
    private var rowLeading: some View {
        if let path = item.displayImagePath, let thumb = vm.thumbImages[path] {
            Image(nsImage: thumb)
                .resizable()
                .scaledToFill()
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line.opacity(0.5), lineWidth: 0.5))
        } else {
            RoundedRectangle(cornerRadius: 5)
                .fill(Theme.pill)
                .frame(width: 24, height: 24)
        }
    }

    @ViewBuilder
    private var previewLine: some View {
        switch item.kind {
        case .text:
            Text(item.textContent?.replacingOccurrences(of: "\n", with: " ") ?? "")
        case .image:
            Text("图片")
        case .screenshot:
            Text("截图")
        case .files:
            if let imagePath = item.imageFilePath {
                Text((imagePath as NSString).lastPathComponent)
            } else {
                Text(item.textContent?.split(separator: "\n").first.map(String.init) ?? "文件")
            }
        }
    }

    @ViewBuilder
    private func contextActions() -> some View {
        Button("粘贴") { actions.activate(item, paste: appState.settings.autoPaste) }
        Button("仅复制") { actions.activate(item, paste: false) }
        if item.kind == .text {
            Button("复制为纯文本") { actions.copyPlain(item) }
        }
        if item.isVisual {
            Button("标注") { actions.annotate(item) }
        }
        Divider()
        Button(item.pinned ? "取消置顶" : "置顶") { actions.togglePin(item) }
        if item.isVisual {
            Button("贴图") { _ = actions.pinToScreen(item) }
        }
        Divider()
        Button("删除", role: .destructive) { actions.delete(item) }
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
                    Divider().overlay(Theme.line)
                    footer(for: item)           // 操作按钮 + 元信息
                }
                .task(id: item.id) {
                    vm.detailIcon = nil
                    vm.detailTransformed = nil
                    vm.detailTransformKey = nil
                    vm.detailImage = nil
                    // 大图优先（降采样后台解码），再补来源图标
                    if let path = item.displayImagePath {
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
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 底部：操作按钮 + 元信息

    private func footer(for item: ClipItem) -> some View {
        VStack(spacing: 6) {
            // 主按钮组流式换行；删除固定右缘（窄面板主按钮折行时仍贴右）
            HStack(alignment: .center, spacing: 6) {
                FlowLayout(spacing: 6) {
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
                    if item.isVisual {
                        detailButton("贴图", symbol: "pin.fill") {
                            _ = actions.pinToScreen(item)
                        }
                        detailButton("标注", symbol: "pencil.and.outline") {
                            actions.annotate(item)
                        }
                        if let path = item.displayImagePath {
                            detailButton("访达", symbol: "folder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            }
                        }
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
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    /// magpie text 按钮：pill 底 + 发丝线（浅色下与纯白详情区有边界），已应用态 accentSoft+accent
    private func detailButton(_ title: String, symbol: String, role: ButtonRole? = nil,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .labelStyle(.titleAndIcon)
                .fixedSize()
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Theme.red : Theme.fg2)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(role == .destructive ? Theme.redSoft : Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(role == .destructive ? Theme.red.opacity(0.4) : Theme.line, lineWidth: 0.5)
        )
        .help(title)
    }

    // MARK: 内容区（详情主体）

    @ViewBuilder
    private func content(for item: ClipItem) -> some View {
        if item.isVisual {
            imageContent(for: item)
        } else {
            switch item.kind {
            case .text:
                textContent(for: item)
            case .files:
                filesContent(for: item)
            default:
                imageContent(for: item)
            }
        }
    }

    /// 图片：撑满可用空间的大图预览（后台降采样解码，加载中显示占位）
    @ViewBuilder
    private func imageContent(for item: ClipItem) -> some View {
        if let path = item.displayImagePath {
            if let image = vm.detailImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.pill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(ProgressView())
                    .padding(12)
            }
        } else {
            Image(systemName: "photo")
                .font(.system(size: 40))
                .foregroundStyle(Theme.faint)
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
                    .foregroundStyle(Theme.fg)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .scrollIndicators(.never)
        }
    }

    /// 文本工具行：流式布局自动换行（此前横向滚动 + 无滚动条，末尾按钮被裁切且无任何可滚提示）
    private func toolRow(for item: ClipItem) -> some View {
        let hints = Self.hintKeys(for: item.textContent ?? "")
        return FlowLayout(spacing: 6) {
            ForEach(Self.tools, id: \.key) { tool in
                let applied = vm.detailTransformKey == tool.key
                let hinted = hints.contains(tool.key) && !applied
                Button {
                    applyTransform(tool.key, item)
                } label: {
                    Text(tool.title)
                        .font(.system(size: 11, weight: applied ? .semibold : .regular))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .fixedSize()
                        .overlay(alignment: .topTrailing) {
                            if hinted {
                                Circle()
                                    .fill(Theme.accent)
                                    .frame(width: 5, height: 5)
                                    .offset(x: 2, y: -1)
                            }
                        }
                }
                .buttonStyle(.plain)
                .foregroundStyle(applied ? Theme.accent : Theme.fg2)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(applied ? Theme.accentSoft : Theme.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(applied ? Color.clear : Theme.line, lineWidth: 0.5)
                )
                .help(hinted ? "内容看起来适合此工具" : tool.title)
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
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.ctlFg)
                .background(Theme.pill, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private struct TextTool {
        let key: String
        let title: String
    }

    private static let tools: [TextTool] = [
        TextTool(key: "newlines", title: "去换行"),
        TextTool(key: "spaces", title: "去空格"),
        TextTool(key: "json", title: "JSON 美化"),
        TextTool(key: "urldecode", title: "URL 解码"),
        TextTool(key: "timestamp", title: "时间戳→日期"),
        TextTool(key: "base64", title: "Base64 解码"),
        TextTool(key: "upper", title: "转大写"),
        TextTool(key: "lower", title: "转小写"),
        TextTool(key: "html", title: "HTML→文本"),
        TextTool(key: "translation", title: "翻译"),
    ]

    /// 智能提示：内容形态匹配的工具加强调点
    private static func hintKeys(for text: String) -> Set<String> {
        var hints = Set<String>()
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return hints }
        if t.hasPrefix("{") || t.hasPrefix("["),
           (try? JSONSerialization.jsonObject(with: Data(t.utf8))) != nil {
            hints.insert("json")
        }
        if t.range(of: "%[0-9A-Fa-f]{2}", options: .regularExpression) != nil {
            hints.insert("urldecode")
        }
        let digits = t.replacingOccurrences(of: " ", with: "")
        if !digits.isEmpty, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }), [10, 13].contains(digits.count) {
            hints.insert("timestamp")
        }
        if t.count >= 16, t.range(of: #"^[A-Za-z0-9+/=]+[=:;,]*$"#, options: .regularExpression) != nil {
            hints.insert("base64")
        }
        let lower = t.lowercased()
        if lower.contains("<p>") || lower.contains("<br") || lower.contains("<html") || lower.contains("<div") {
            hints.insert("html")
        }
        return hints
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
            guard !digits.isEmpty, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }) else {
                appState.showToast("内容不是纯数字时间戳")
                return
            }
            let interval: TimeInterval
            if digits.count >= 13 {
                interval = Double(digits.prefix(13)) ?? 0
            } else {
                interval = Double(digits.prefix(10)) ?? 0
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            result = formatter.string(from: Date(timeIntervalSince1970: interval))
        case "base64":
            let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = Data(base64Encoded: trimmed), let s = String(data: data, encoding: .utf8) {
                result = s
            } else {
                appState.showToast("不是有效的 Base64（或不是 UTF-8 文本）")
                return
            }
        case "upper":
            result = original.uppercased()
        case "lower":
            result = original.lowercased()
        case "html":
            var s = original.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            let entities = [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")]
            for (entity, replacement) in entities {
                s = s.replacingOccurrences(of: entity, with: replacement)
            }
            while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
            result = s.trimmingCharacters(in: .whitespacesAndNewlines)
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
                                .foregroundStyle(Theme.ctlFg)
                            Text((path as NSString).lastPathComponent)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.fg2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text("在访达中显示")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.accent)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
                Text("点击条目在访达中显示文件")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
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
                .foregroundStyle(Theme.faint)
            Text("选择左侧条目查看详情")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension Text {
    func keyStyle() -> some View {
        font(.system(size: 10.5))
            .foregroundStyle(Theme.muted)
    }
}

/// 流式布局：子视图放不下自动折行（工具行/详情按钮组用，替代会被裁切的横向滚动）
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxW {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        let width = maxW.isFinite ? maxW : max(x - spacing, 0)
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
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
