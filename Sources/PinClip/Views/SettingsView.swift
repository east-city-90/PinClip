import AppKit
import SwiftUI

/// 设置视图模型（CLT 环境无 @State 宏插件，状态集中在此 @Observable VM，由窗口控制器持有）
@MainActor
@Observable
final class SettingsVM {
    enum Section: String, CaseIterable, Identifiable {
        case general = "通用"
        case hotkeys = "快捷键"
        case history = "历史"
        case privacy = "隐私"
        case about = "关于"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .hotkeys: return "command"
            case .history: return "clock.arrow.circlepath"
            case .privacy: return "hand.raised"
            case .about: return "info.circle"
            }
        }
    }

    var section: Section = .general
    var autostart = false
    var recordingAction: HotkeyAction?
    var pendingClearImages = false
    var pendingClearAll = false
    var excludedText = ""
    var toast: String?
    var toastClearTask: Task<Void, Never>?

    func showToast(_ text: String) {
        toast = text
        toastClearTask?.cancel()
        toastClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self?.toast == text { self?.toast = nil }
        }
    }
}

/// 设置视图（magpie：毛玻璃无边框窗 + 自定义侧栏 + 卡片分区 + 靛蓝 tint）
struct SettingsView: View {
    let appState: AppState
    let vm: SettingsVM

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏区（红绿灯按钮悬浮于此，文字居中模拟原生标题）
            ZStack {
                Text("设置 · PinClip 贴剪")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 158)
                    .background(Theme.bg)
                Divider().overlay(Theme.line)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Theme.bg)
            }
        }
        .frame(width: 720, height: 548)
        .tint(Theme.accent)
        .onAppear {
            vm.autostart = appState.launchManager?.isEnabled ?? false
            vm.excludedText = appState.settings.excludedBundles.joined(separator: "\n")
            appState.refreshPermissions()
        }
        .onChange(of: appState.toastText) { _, text in
            guard let text else { return }
            vm.showToast(text)
        }
        .overlay(alignment: .bottom) {
            if let toast = vm.toast {
                ToastView(text: toast).padding(.bottom, 16)
            }
        }
        .alert("清空全部历史？", isPresented: Binding(
            get: { vm.pendingClearAll },
            set: { vm.pendingClearAll = $0 }
        )) {
            Button("清空", role: .destructive) { appState.historyStore?.clearAll(imagesOnly: false) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有文本、图片、文件记录都将被删除，置顶项也会清除。")
        }
        .alert("清空全部图片记录？", isPresented: Binding(
            get: { vm.pendingClearImages },
            set: { vm.pendingClearImages = $0 }
        )) {
            Button("清空", role: .destructive) { appState.historyStore?.clearAll(imagesOnly: true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("截图与复制的图片（含媒体文件）都将被删除，置顶项也会清除。")
        }
    }

    // MARK: 侧栏（靛蓝选中导航，全行命中）

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsVM.Section.allCases) { s in
                let selected = vm.section == s
                Button {
                    vm.section = s
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: s.symbol)
                            .font(.system(size: 12))
                            .frame(width: 16)
                        Text(s.rawValue)
                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? Theme.accent : Theme.muted)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(selected ? Theme.accent.opacity(0.14) : Color.clear)
                )
                .padding(.horizontal, 8)
            }
            Spacer()
        }
        .padding(.top, 12)
    }

    // MARK: 内容区（卡片分区）

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch vm.section {
                case .general: generalSection
                case .hotkeys: hotkeysSection
                case .history: historySection
                case .privacy: privacySection
                case .about: aboutSection
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func card<Content: View>(@ViewBuilder _ inner: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { inner() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.card)
                    .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Theme.line2, lineWidth: 0.5)
            )
    }

    // MARK: 通用

    private var generalSection: some View {
        Group {
            sectionTitle("通用")
            card {
                Toggle("开机自动启动 PinClip", isOn: Binding(
                    get: { vm.autostart },
                    set: { newValue in
                        do {
                            if newValue { try appState.launchManager?.enable() } else { try appState.launchManager?.disable() }
                            vm.autostart = newValue
                        } catch {
                            vm.showToast("设置开机自启失败：\(error.localizedDescription)")
                        }
                    }
                ))
                Text("仅对打包后的 PinClip.app 生效")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
            }
            card {
                HStack {
                    Text("截图保存目录")
                    Spacer()
                    Text((appState.settings.saveDir as NSString).expandingTildeInPath)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                    Button("在访达中打开") { appState.openSaveFolder() }
                        .font(.system(size: 11))
                        .buttonStyle(.link)
                }
                Toggle("截图默认带背景 + 阴影装饰（适合分享）", isOn: Binding(
                    get: { appState.settings.captureDecoration },
                    set: { newValue in appState.updateSettings { $0.captureDecoration = newValue } }
                ))
                Toggle("截图时左上角显示尺寸角标", isOn: Binding(
                    get: { appState.settings.showSizeBadge },
                    set: { newValue in appState.updateSettings { $0.showSizeBadge = newValue } }
                ))
            }
            card {
                Toggle("导出截图叠加自定义水印", isOn: Binding(
                    get: { !appState.settings.watermarkText.isEmpty },
                    set: { newValue in appState.updateSettings {
                        $0.watermarkText = newValue ? (appState.settings.watermarkText.isEmpty ? "@我" : appState.settings.watermarkText) : ""
                    } }
                ))
                if !appState.settings.watermarkText.isEmpty {
                    TextField("水印文字", text: Binding(
                        get: { appState.settings.watermarkText },
                        set: { newValue in appState.updateSettings { $0.watermarkText = newValue } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    Picker("位置", selection: Binding(
                        get: { appState.settings.watermarkCorner },
                        set: { newValue in appState.updateSettings { $0.watermarkCorner = newValue } }
                    )) {
                        Text("左上").tag("topLeft")
                        Text("右上").tag("topRight")
                        Text("左下").tag("bottomLeft")
                        Text("右下").tag("bottomRight")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    HStack {
                        Text("不透明度")
                        Slider(value: Binding(
                            get: { appState.settings.watermarkOpacity },
                            set: { newValue in appState.updateSettings { $0.watermarkOpacity = newValue } }
                        ), in: 0.2...0.9)
                    }
                }
                Text("水印叠加在复制 / 保存 / 贴图的截图上，跟随深浅色自动加投影")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    // MARK: 快捷键

    private var hotkeysSection: some View {
        Group {
            sectionTitle("快捷键")
            card {
                Text("与其他应用冲突时 PinClip 会自动尝试备选键；点击「录制」可自定义。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                ForEach(HotkeyAction.allCases, id: \.self) { action in
                    HStack {
                        Text(action.displayName).font(.system(size: 13))
                        Spacer()
                        if vm.recordingAction == action {
                            Text("按下新快捷键…（Esc 取消）")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.accent)
                        } else {
                            Text(appState.settings.hotkeys[action]?.display ?? "未设置")
                                .font(.system(size: 12, weight: .medium).monospaced())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Theme.pill, in: RoundedRectangle(cornerRadius: 6))
                            Button("录制") { startRecording(action) }
                                .font(.system(size: 11))
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Button("恢复默认快捷键") { appState.resetHotkeys() }
                    .font(.system(size: 12))
                    .buttonStyle(.bordered)
            }
        }
    }

    private func startRecording(_ action: HotkeyAction) {
        vm.recordingAction = action
        HotkeyRecorder.shared.begin { spec in
            vm.recordingAction = nil
            guard let spec else { return }
            if appState.rebindHotkey(action, spec) {
                appState.updateSettings { $0.hotkeys[action] = spec }
                vm.showToast("\(action.displayName) 已改为 \(spec.display)")
            } else {
                vm.showToast("快捷键 \(spec.display) 被占用，请换一个")
            }
        }
    }

    // MARK: 历史

    private var historySection: some View {
        Group {
            sectionTitle("历史")
            card {
                Stepper(value: Binding(
                    get: { appState.settings.textLimit },
                    set: { newValue in appState.updateSettings { $0.textLimit = newValue } }
                ), in: 100...5000, step: 100) {
                    Text("文本历史上限：\(appState.settings.textLimit) 条")
                        .font(.system(size: 13))
                }
                Stepper(value: Binding(
                    get: { appState.settings.imageDays },
                    set: { newValue in appState.updateSettings { $0.imageDays = newValue } }
                ), in: 1...365) {
                    Text("图片保留：\(appState.settings.imageDays) 天")
                        .font(.system(size: 13))
                }
                Text("置顶（收藏）条目不受清理影响")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
            }
            card {
                HStack(spacing: 12) {
                    Button("仅清空图片", role: .destructive) { vm.pendingClearImages = true }
                    Button("清空全部历史", role: .destructive) { vm.pendingClearAll = true }
                    Button("打开数据文件夹") { appState.openSaveFolder() }
                }
                .font(.system(size: 12))
            }
        }
    }

    // MARK: 隐私

    private var privacySection: some View {
        Group {
            sectionTitle("隐私")
            card {
                Toggle("单击条目后自动粘贴到原应用", isOn: Binding(
                    get: { appState.settings.autoPaste },
                    set: { newValue in appState.updateSettings { $0.autoPaste = newValue } }
                ))
                HStack(spacing: 6) {
                    Circle()
                        .fill(appState.axPermission ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(appState.axPermission ? "辅助功能权限已授予（自动粘贴可用）" : "需要辅助功能权限才能自动粘贴，未授权时自动降级为仅复制")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                    if !appState.axPermission {
                        Button("打开系统设置") { appState.openAXPermissionSettings() }
                            .font(.system(size: 11))
                            .buttonStyle(.link)
                    }
                }
            }
            card {
                Toggle("敏感内容过滤（密码/银行卡号/私钥不入库）", isOn: Binding(
                    get: { appState.settings.sensitiveFilter },
                    set: { newValue in appState.updateSettings { $0.sensitiveFilter = newValue } }
                ))
                Toggle("在线获取网站图标（复制链接时显示 favicon，仅直接请求目标网站，无第三方服务）", isOn: Binding(
                    get: { appState.settings.webFaviconEnabled },
                    set: { newValue in appState.updateSettings { $0.webFaviconEnabled = newValue } }
                ))
            }
            card {
                Text("以下来源应用不会被记录（bundle id，每行一个）：")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                TextEditor(text: Binding(
                    get: { vm.excludedText },
                    set: { vm.excludedText = $0 }
                ))
                .font(.system(size: 11).monospaced())
                .frame(height: 100)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Theme.pill, in: RoundedRectangle(cornerRadius: 8))
                .onDisappear { syncExcludedBundles() }
            }
        }
    }

    private func syncExcludedBundles() {
        let lines = vm.excludedText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if lines != appState.settings.excludedBundles {
            appState.updateSettings { $0.excludedBundles = lines }
        }
    }

    // MARK: 关于

    private var aboutSection: some View {
        Group {
            sectionTitle("关于")
            card {
                HStack(spacing: 10) {
                    Image(systemName: "pin.circle.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PinClip 贴剪").font(.system(size: 15, weight: .semibold))
                        Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0-dev")")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.muted)
                    }
                }
                Text("截图 + 贴图 + 剪贴板历史，三合一轻量工具。全本地处理，无遥测。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }
        }
    }
}

private func sectionTitle(_ title: String) -> some View {
    Text(title)
        .font(.system(size: 14, weight: .semibold))
        .padding(.top, 4)
}

// MARK: - 快捷键录制器

@MainActor
final class HotkeyRecorder {
    static let shared = HotkeyRecorder()
    private var monitor: Any?
    private var completion: ((HotkeySpec?) -> Void)?

    func begin(completion: @escaping (HotkeySpec?) -> Void) {
        cancel()
        self.completion = completion
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let keyCode = event.keyCode

            // Esc 取消
            if keyCode == 53 {
                self.finish(with: nil)
                return nil
            }

            let useCommand = flags.contains(.command)
            let useOption = flags.contains(.option)
            let useControl = flags.contains(.control)
            let useShift = flags.contains(.shift)
            let isFKey = keyCode >= 0x70

            // 需要至少一个修饰键，或单独的 F 键
            guard isFKey || (useCommand || useOption || useControl) else { return nil }
            guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return nil }

            var display = ""
            if useCommand { display += "⌘" }
            if useOption { display += "⌥" }
            if useControl { display += "⌃" }
            if useShift { display += "⇧" }
            display += Self.keyName(keyCode: UInt32(keyCode), chars: chars)

            self.finish(with: HotkeySpec(
                keyCode: UInt32(keyCode),
                useCommand: useCommand, useOption: useOption,
                useControl: useControl, useShift: useShift,
                display: display
            ))
            return nil
        }
    }

    private func finish(with spec: HotkeySpec?) {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        completion?(spec)
        completion = nil
    }

    func cancel() {
        finish(with: nil)
    }

    private static func keyName(keyCode: UInt32, chars: String) -> String {
        let fKeys: [UInt32: String] = [
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 103: "F5", 111: "F6",
            105: "F7", 106: "F8", 107: "F9", 109: "F10", 113: "F11", 114: "F12",
        ]
        if let name = fKeys[keyCode] { return name }
        return chars.uppercased()
    }
}
