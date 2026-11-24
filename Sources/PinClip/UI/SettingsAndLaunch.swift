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

/// 设置窗口（720×520，原生标题栏 + SwiftUI SettingsView 承载）
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
            // 原生标题栏：fullSizeContentView 消除系统亮边（曾出现的"白线"），
            // 标题文字由系统绘制（titleVisibility=.visible）——自绘 28pt 标题条会与
            // macOS 26+ 的更高标题栏叠加，导致 titlebar 过高（2026-11-25 用户反馈已修）
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "设置 · PinClip 贴剪"
            window.isReleasedWhenClosed = false
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .visible
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
