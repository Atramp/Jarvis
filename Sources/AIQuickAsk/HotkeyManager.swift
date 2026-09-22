import AppKit

/// 快捷键管理：双击右侧 Command 键触发。
/// 实现：全局监听 flagsChanged，区分左右 Command（右 = keyCode 0x36），按两次「按下」的时间间隔判断双击。
/// 注意：全局监听按键事件需要「辅助功能」权限（AppDelegate 启动时会引导授权）。
final class HotkeyManager {
    var onTrigger: (() -> Void)?

    /// 右侧 Command 的虚拟键码（kVK_RightCommand = 0x36 = 54）
    private let rightCommandKeyCode: UInt16 = 0x36
    /// 双击判定阈值（秒）
    private let doubleTapThreshold: TimeInterval = 0.35

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastPressTime: TimeInterval = 0
    /// 右 Command 当前是否按下（翻转判定用，见 handleFlagsChanged）。
    private var rightCommandDown = false

    func register() {
        unregister()

        // 全局监听：捕获其他应用中的按键（面板未聚焦时）
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        // 本地监听：捕获本应用内的按键（面板已聚焦时，用于双击再次收起）
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    func unregister() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
        lastPressTime = 0
        rightCommandDown = false
    }

    // MARK: - 事件处理

    private func handleFlagsChanged(_ event: NSEvent) {
        // 只关心右侧 Command 键
        guard event.keyCode == rightCommandKeyCode else { return }

        // flagsChanged 对同一键的「按下」和「松开」各触发一次：用状态翻转判定按下沿。
        // 不能看 modifierFlags.contains(.command)——它反映所有修饰键的合计状态，
        // 按住左 ⌘ 时单击右 ⌘，松开右 ⌘ 的瞬间 flags 仍含 .command，会被误判为又一次按下。
        rightCommandDown.toggle()
        guard rightCommandDown else { return }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastPressTime < doubleTapThreshold {
            // 双击命中
            lastPressTime = 0
            DispatchQueue.main.async { [weak self] in
                self?.onTrigger?()
            }
        } else {
            lastPressTime = now
        }
    }
}
