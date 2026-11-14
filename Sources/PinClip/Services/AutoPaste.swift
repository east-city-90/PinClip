import ApplicationServices
import CoreGraphics
import Foundation

/// 自动粘贴：辅助功能权限检查 + 合成 ⌘V（设计方案 §5.3 自动粘贴）
enum AutoPaste {

    static func isProcessTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// 向当前前台 App 发送 ⌘V。调用前应先回填剪贴板并让面板退出（非激活面板不影响前台 App）。
    /// delayMs：等面板隐藏、目标 App 恢复按键焦点的缓冲。
    static func postCommandV(delayMs: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(delayMs) / 1000.0) {
            postKeyCommandV()
        }
    }

    private static func postKeyCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true), // V
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            up.post(tap: .cghidEventTap)
        }
    }
}
