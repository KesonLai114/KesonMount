import AppKit
import ApplicationServices

/// 全局快捷键。
///
/// 菜单栏 App 的主战场是「不切窗口也能干活」：一边改文档一边想把 NAS 的盘挂上，
/// 总不能先点一下图标。AutoMounter / Mountain 这类竞品都做了系统级快捷键，
/// 这里补上。
///
/// 注意：全局监听键盘事件需要「辅助功能」权限。没授权时全局监视器收不到事件，
/// 而且不会报错——所以要先用 AXIsProcessTrusted 问清楚，没权限就明确引导用户去开。
final class HotkeyManager {

    static let shared = HotkeyManager()

    struct Shortcut {
        let keyCode: UInt16
        let modifiers: NSEvent.ModifierFlags
        /// 展示用，如 ⌥⌘M
        let keys: String
        let title: String
    }

    /// 三个够用：显示主窗口、挂载全部、卸载全部
    static let shortcuts: [Shortcut] = [
        Shortcut(keyCode: 46, modifiers: [.option, .command], keys: "⌥⌘M", title: "显示 / 隐藏主窗口"),
        Shortcut(keyCode: 40, modifiers: [.option, .command], keys: "⌥⌘K", title: "挂载全部磁盘"),
        Shortcut(keyCode: 32, modifiers: [.option, .command], keys: "⌥⌘U", title: "卸载全部磁盘")
    ]

    /// keyCode → 处理函数
    private var actions: [UInt16: () -> Void] = [:]
    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// 是否已获得辅助功能权限
    var isTrusted: Bool { AXIsProcessTrusted() }

    /// 没权限时弹系统提示，引导用户去授权
    @discardableResult
    func requestPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// 注册快捷键。action 由 keyCode 索引。
    func register(actions: [UInt16: () -> Void]) {
        stop()
        self.actions = actions
        guard !actions.isEmpty else { return }

        // 全局监视器：在别的 App 里按下也能收到
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
        }
        // 本地监视器：本 App 是前台时也要能响应（全局监视器收不到自己的事件）
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor { NSEvent.removeMonitor(l) }
        globalMonitor = nil
        localMonitor = nil
        actions = [:]
    }

    private func handle(_ event: NSEvent) {
        // 忽略自己按的修饰键（按 ⌥ 也会产生 keyDown 事件）
        let meaningful = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let action = actions[event.keyCode] else { return }
        for s in HotkeyManager.shortcuts where s.keyCode == event.keyCode {
            guard meaningful.contains(s.modifiers) else { return }
        }
        // 全局监视器在后台线程回调，UI 操作必须回主线程
        DispatchQueue.main.async { action() }
    }

    /// 给界面看的快捷键说明
    static func describe() -> [[String: String]] {
        shortcuts.map { ["keys": $0.keys, "title": $0.title] }
    }
}
