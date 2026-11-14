import AppKit

// PinClip · 截图 + 贴图 + 剪贴板三合一 · 常驻菜单栏应用（LSUIElement）
// 顶层代码运行在主线程，直接沿用主 actor 隔离
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // 菜单栏应用：不显示 Dock 图标
    app.run()
}
