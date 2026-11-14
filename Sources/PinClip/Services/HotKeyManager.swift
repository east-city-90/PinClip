import AppKit
import Carbon.HIToolbox

/// Carbon 事件回调（C 函数指针，必须是文件级非隔离函数）
private func pinclipHotKeyCallback(_ nextHandler: EventHandlerCallRef?,
                                   _ event: EventRef?,
                                   _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, let userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            manager.dispatch(id: hotKeyID.id)
        }
    }
    return noErr
}

/// 全局热键：Carbon RegisterEventHotKey（无需任何权限，注册失败即冲突）
/// 冲突策略（设计方案 §3.2）：⌥A 被占用时自动尝试备选键，并向 UI 报告最终生效键
@MainActor
final class HotKeyManager {
    private var registrations: [HotkeyAction: EventHotKeyRef?] = [:]
    private var specs: [HotkeyAction: HotkeySpec] = [:]
    private var handlers: [HotkeyAction: () -> Void] = [:]
    private var idToAction: [UInt32: HotkeyAction] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false

    private static let signature: FourCharCode = {
        let chars: [UInt8] = [0x50, 0x43, 0x4C, 0x50] // "PCLP"
        return FourCharCode(chars[0]) << 24 | FourCharCode(chars[1]) << 16 | FourCharCode(chars[2]) << 8 | FourCharCode(chars[3])
    }()

    // MARK: 注册

    /// 批量注册；返回每个动作的注册错误（nil = 成功或走了备选）
    func registerAll(specs: [HotkeyAction: HotkeySpec],
                     handlers: [HotkeyAction: () -> Void],
                     fallbacks: [HotkeyAction: [HotkeySpec]]) -> [HotkeyAction: OSStatus] {
        self.handlers = handlers
        var failures: [HotkeyAction: OSStatus] = [:]
        for action in HotkeyAction.allCases {
            guard let handler = handlers[action] else { continue }
            let candidates = [specs[action]].compactMap { $0 } + (fallbacks[action] ?? [])
            var registered = false
            var lastError: OSStatus = 0
            for candidate in candidates {
                if tryRegister(action: action, spec: candidate, handler: handler) {
                    registered = true
                    break
                } else {
                    lastError = OSStatus(eventHotKeyExistsErr)
                }
            }
            if !registered {
                failures[action] = lastError
            }
        }
        for action in HotkeyAction.allCases {
            if let spec = specs[action] {
                NSLog("PinClip.hotkey: 已注册 \(action.rawValue) -> \(spec.display) (key=\(spec.keyCode) mods=\(Self.carbonModifiers(of: spec)))")
            } else if failures[action] != nil {
                NSLog("PinClip.hotkey: 注册失败 \(action.rawValue) status=\(failures[action]!)")
            }
        }
        return failures
    }

    /// 重新绑定（设置页）；false = 与其他 App 冲突
    @discardableResult
    func rebind(action: HotkeyAction, spec: HotkeySpec) -> Bool {
        guard let handler = handlers[action] else { return false }
        unregister(action: action)
        return tryRegister(action: action, spec: spec, handler: handler)
    }

    func spec(for action: HotkeyAction) -> HotkeySpec? {
        specs[action]
    }

    private func tryRegister(action: HotkeyAction, spec: HotkeySpec, handler: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        unregister(action: action)

        var ref: EventHotKeyRef?
        let id = nextID
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            spec.keyCode,
            Self.carbonModifiers(of: spec),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, ref != nil else { return false }
        nextID += 1
        registrations[action] = Optional(ref)
        specs[action] = spec
        idToAction[id] = action
        handlers[action] = handler
        return true
    }

    private func unregister(action: HotkeyAction) {
        if let ref = registrations[action], let hotKeyRef = ref {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let oldID = idToAction.first(where: { $0.value == action })?.key {
            idToAction.removeValue(forKey: oldID)
        }
        registrations.removeValue(forKey: action)
        specs.removeValue(forKey: action)
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            pinclipHotKeyCallback,
            1,
            &eventType,
            userData,
            nil
        )
        NSLog("PinClip.hotkey: InstallEventHandler status=\(status)")
        handlerInstalled = status == noErr
    }

    fileprivate func dispatch(id: UInt32) {
        guard let action = idToAction[id], let handler = handlers[action] else {
            NSLog("PinClip.hotkey: 收到热键但无法匹配 id=\(id)")
            return
        }
        NSLog("PinClip.hotkey: 触发 \(action.rawValue)")
        handler()
    }

    private static func carbonModifiers(of spec: HotkeySpec) -> UInt32 {
        var mods: UInt32 = 0
        if spec.useCommand { mods |= UInt32(cmdKey) }
        if spec.useShift { mods |= UInt32(shiftKey) }
        if spec.useOption { mods |= UInt32(optionKey) }
        if spec.useControl { mods |= UInt32(controlKey) }
        return mods
    }
}
