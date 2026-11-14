import AppKit
import ServiceManagement
import SwiftUI

/// 开机自启（SMAppService，macOS 13+；仅打包后的 .app 生效）
@MainActor
protocol LaunchAtStartupManaging: AnyObject {
    var isEnabled: Bool { get }
    func enable() throws
    func disable() throws
}

@MainActor
final class LaunchAtStartupManager: LaunchAtStartupManaging {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func enable() throws {
        try SMAppService.mainApp.register()
    }

    func disable() throws {
        try SMAppService.mainApp.unregister()
    }
}

/// 无边框窗口需要显式声明可成为 key window（设置里有输入框/录制器）
final class FramelessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// 设置窗口（720×520，magpie 毛玻璃无边框 + 自定义标题栏，SwiftUI SettingsView 承载）
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private var settingsVM: SettingsVM?
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func show(initialSection: SettingsVM.Section? = nil) {
        NSLog("PinClip.debug: 打开设置窗口 section=\(initialSection?.rawValue ?? "记忆")")
        if window == nil, let appState {
            let vm = SettingsVM()
            if let initialSection { vm.section = initialSection }
            settingsVM = vm
            // 原生 Mac 风格：标准标题栏 + 红绿灯按钮
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "设置 · PinClip 贴剪"
            window.isReleasedWhenClosed = false
            // 内容延伸至标题栏下方：保留红绿灯按钮，消除系统窗口亮边
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = NSColor.windowBackgroundColor
            window.contentView = NSHostingView(rootView: SettingsView(appState: appState, vm: vm))
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        if let initialSection, let vm = settingsVM {
            vm.section = initialSection
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
