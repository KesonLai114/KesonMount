import AppKit
import ServiceManagement

/// 应用级偏好设置：开机启动、隐藏程序坞图标、菜单栏图标。
///
/// 这三项都不属于某一块磁盘，所以单独放一份，用 UserDefaults 持久化。
final class AppSettings {

    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let hideDock = "settings.hideDockIcon"
        static let showStatusBar = "settings.showStatusBarIcon"
        static let didMigrate = "settings.didMigrateToSMAppService"
        static let watchdog = "settings.watchdogEnabled"
        static let notify = "settings.notifyEvents"
        static let closeMinimizes = "settings.closeWindowMinimizes"
        static let globalHotkeys = "settings.globalHotkeysEnabled"
    }

    /// 设置变化时回调（主线程），用来刷新界面与菜单勾选状态
    var onChange: (() -> Void)?

    private init() {}

    // MARK: 程序坞图标

    var hideDockIcon: Bool {
        get { defaults.bool(forKey: Key.hideDock) }
        set {
            defaults.set(newValue, forKey: Key.hideDock)
            applyActivationPolicy()
            notify()
        }
    }

    /// 立即生效。`.accessory` = 不出现在程序坞，也不抢焦点；
    /// `.regular` = 正常 App。菜单栏图标两种模式下都在。
    func applyActivationPolicy() {
        NSApp.setActivationPolicy(hideDockIcon ? .accessory : .regular)
    }

    // MARK: 菜单栏图标

    /// 默认显示：用户要的就是「通知栏有个图标」
    var showStatusBarIcon: Bool {
        get {
            defaults.object(forKey: Key.showStatusBar) == nil
                ? true
                : defaults.bool(forKey: Key.showStatusBar)
        }
        set {
            defaults.set(newValue, forKey: Key.showStatusBar)
            notify()
        }
    }

    // MARK: 开机启动

    /// 用 SMAppService 查询，这是 macOS 13 起的官方做法
    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }
    /// 有些状态需要用户手动去系统设置里批，这里翻译成人话
    var launchAtLoginHint: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "已开启，登录后自动启动"
        case .requiresApproval:
            return "需要在「系统设置 › 通用 › 登录项与扩展 › 允许在后台运行」里手动打开"
        case .notFound, .notRegistered:
            return "未开启"
        @unknown default:
            return "状态未知"
        }
    }

    /// 切换开机启动。返回 nil 表示成功，否则返回人话错误
    @discardableResult
    func setLaunchAtLogin(_ on: Bool) -> String? {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            notify()
            return nil
        } catch {
            let ns = error as NSError
            // -54 是权限被占；常见于 App 不在「应用程序」文件夹里
            if ns.domain == NSCocoaErrorDomain, ns.code == 512 {
                return "开启失败：请把「网盘管家」拖到「应用程序」文件夹后再试（macOS 要求登录项必须是装好的 App）"
            }
            return "设置失败：\(error.localizedDescription)"
        }
    }

    private func notify() {
        if Thread.isMainThread {
            onChange?()
        } else {
            DispatchQueue.main.async { [weak self] in self?.onChange?() }
        }
    }

    // MARK: 掉线自动重挂

    /// 默认开：SMB 自己掉线是常态，用户不该每次手动点「挂载」
    var watchdogEnabled: Bool {
        get {
            defaults.object(forKey: Key.watchdog) == nil
                ? true
                : defaults.bool(forKey: Key.watchdog)
        }
        set {
            defaults.set(newValue, forKey: Key.watchdog)
            notify()
        }
    }

    // MARK: 系统通知

    /// 掉线 / 重连成功时发系统通知。隐藏程序坞图标后这是唯一能提醒到用户的渠道
    var notifyEvents: Bool {
        get {
            defaults.object(forKey: Key.notify) == nil
                ? true
                : defaults.bool(forKey: Key.notify)
        }
        set {
            defaults.set(newValue, forKey: Key.notify)
            notify()
        }
    }

    // MARK: 主窗口关闭行为

    /// 点主窗口关闭按钮时：
    /// true = 最小化 / 藏到后台（程序继续运行，从菜单栏或程序坞图标重新打开）；
    /// false = 直接退出 App。
    /// 默认值跟随「是否隐藏程序坞」：菜单栏模式下关窗不该退出（那是唯一入口），
    /// 普通程序坞模式默认直接退出（更直觉）。一旦用户手动改过就按他选的来。
    var closeMinimizes: Bool {
        get {
            if defaults.object(forKey: Key.closeMinimizes) != nil {
                return defaults.bool(forKey: Key.closeMinimizes)
            }
            return hideDockIcon
        }
        set {
            defaults.set(newValue, forKey: Key.closeMinimizes)
            notify()
        }
    }

    // MARK: 全局快捷键

    /// 系统级快捷键（在别的 App 里也能用）。默认开。
    /// 真正能不能收到事件，还取决于用户有没有在「辅助功能」里授权——那一层
    /// 由 HotkeyManager 去问，这里只管用户想不想用。
    var globalHotkeysEnabled: Bool {
        get {
            if defaults.object(forKey: Key.globalHotkeys) != nil {
                return defaults.bool(forKey: Key.globalHotkeys)
            }
            return true
        }
        set {
            defaults.set(newValue, forKey: Key.globalHotkeys)
            notify()
        }
    }
}
