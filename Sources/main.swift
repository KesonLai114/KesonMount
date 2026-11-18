import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private var window: NSWindow!
    private var controller: AppController!
    private let statusBar = StatusBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        controller = AppController()

        // 隐身调试模式：只截图，不弹窗、不抢焦点、不占 Dock
        let headless = AppDelegate.isHeadless

        // 程序坞图标按上次的设置来：隐藏时用 .accessory，菜单栏图标照常工作
        if !headless {
            AppSettings.shared.applyActivationPolicy()
        }

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "KesonMount"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.backgroundColor = NSColor.windowBackgroundColor
        window.minSize = NSSize(width: 900, height: 600)

        // 用 RootView 包住 WebView：顶部标题栏区域可拖动窗口，其余交给 WebView
        let root = RootView()
        root.translatesAutoresizingMaskIntoConstraints = false
        controller.webView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(controller.webView)
        NSLayoutConstraint.activate([
            controller.webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            controller.webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            controller.webView.topAnchor.constraint(equalTo: root.topAnchor),
            controller.webView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        window.contentView = root
        window.delegate = self

        if headless {
            // 挪到屏幕外 + 不激活，任何桌面都看不到它
            window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
            window.ignoresMouseEvents = true
            window.orderBack(nil)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        controller.start()

        // 菜单栏（通知栏）图标：隐藏程序坞时它是唯一入口
        if !headless || AppEnvironment.value("DUMP_STATUSBAR") == "1" {
            statusBar.install(
                store: controller.store,
                windowProvider: { [weak self] in self?.window }
            )
        }

        // 全局快捷键：在别的 App 里也能一键挂载 / 卸载 / 唤出窗口
        setupHotkeys()

        // kesonmount:// 深链接（快捷指令、脚本、Raycast 之类调进来）
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        // 自检：打印菜单栏图标菜单结构后退出
        if AppEnvironment.value("DUMP_STATUSBAR") == "1" {
            statusBar.dumpMenu()
            if AppEnvironment.value("DUMP_POPOVER") == "1" {
                statusBar.dumpPopover()
            }
            exit(0)
        }

        // 自检：KESONMOUNT_DUMP_MENU=1 时打印菜单结构与快捷键后退出
        if AppEnvironment.value("DUMP_MENU") == "1" {
            AppDelegate.dumpMenu(NSApp.mainMenu, depth: 0)
            exit(0)
        }
    }

    static func dumpMenu(_ menu: NSMenu?, depth: Int) {
        guard let menu else { return }
        let pad = String(repeating: "  ", count: depth)
        if !menu.title.isEmpty { print("\(pad)[\(menu.title)]") }
        for item in menu.items {
            if item.isSeparatorItem { print("\(pad)  ──"); continue }
            var keys = ""
            if !item.keyEquivalent.isEmpty {
                var mods: [String] = []
                let m = item.keyEquivalentModifierMask
                if m.contains(.control) { mods.append("⌃") }
                if m.contains(.option) { mods.append("⌥") }
                if m.contains(.shift) { mods.append("⇧") }
                if m.contains(.command) { mods.append("⌘") }
                keys = "  " + mods.joined() + item.keyEquivalent
            }
            let hasAction = item.action != nil ? "" : "  (无 action)"
            print("\(pad)  · \(item.title)\(keys)\(hasAction)")
            if let sub = item.submenu { dumpMenu(sub, depth: depth + 1) }
        }
    }

    /// 截图 / 自动化运行时自动进入隐身模式，也可用 KESONMOUNT_HEADLESS=1 强制开启
    static var isHeadless: Bool {
        let env = AppEnvironment.dictionary
        if env["KESONMOUNT_HEADLESS"] == "1" { return true }
        return env["KESONMOUNT_SNAPSHOT"] != nil
    }

    /// 关掉窗口后要不要退出：按设置来。选了「最小化到后台」时即便窗口真的关了也不退
    /// （正常情况窗口根本不会关，因为 windowShouldClose 会改成最小化/藏起来）
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        if AppSettings.shared.closeMinimizes { return false }
        return true
    }

    /// 点主窗口关闭按钮：按设置决定「最小化到后台」还是「直接退出」
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if AppSettings.shared.closeMinimizes {
            if AppSettings.shared.hideDockIcon {
                // 菜单栏模式没有程序坞，直接藏起来，从菜单栏图标再打开
                sender.orderOut(nil)
            } else {
                // 有程序坞：真正最小化到程序坞
                sender.miniaturize(nil)
            }
            return false
        }
        return true
    }

    @objc func refreshNow() {
        controller.refreshNow()
    }

    // MARK: - 全局快捷键

    /// 注册系统级快捷键（⌥⌘M 唤出窗口 / ⌥⌘K 挂载全部 / ⌥⌘U 卸载全部）。
    /// 快捷键要「辅助功能」权限才真正生效；没授权时全局收不到事件，
    /// 但 App 在前台时仍能用，所以注册动作不依赖权限结果。
    private func setupHotkeys() {
        applyHotkeyState()
        // 设置里切换「全局快捷键」时，按开关注册 / 注销
        NotificationCenter.default.addObserver(
            forName: .netMountRefreshHotkeys,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyHotkeyState()
        }
    }

    /// 按当前开关状态注册或注销快捷键
    private func applyHotkeyState() {
        guard AppSettings.shared.globalHotkeysEnabled else {
            HotkeyManager.shared.stop()
            return
        }
        HotkeyManager.shared.register(actions: [
            // ⌥⌘M —— 显示 / 隐藏主窗口
            46: { [weak self] in self?.toggleWindow() },
            // ⌥⌘K —— 挂载全部
            40: { [weak self] in self?.controller?.store.mountAll() },
            // ⌥⌘U —— 卸载全部
            32: { [weak self] in self?.controller?.store.unmountAll() }
        ])
    }

    /// 显示 / 隐藏主窗口（⌥⌘M）
    @objc func toggleWindow() {
        guard let window else { return }
        if window.isVisible, NSApp.isActive {
            window.orderOut(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - 深链接

    /// `open "kesonmount://mountAll"` 之类的入口。
    /// 事件来自任意 App，一律先回主线程再动状态。
    @objc private func handleGetURL(_ event: NSAppleEventDescriptor,
                                    withReply reply: NSAppleEventDescriptor) {
        guard let raw = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return }
        DispatchQueue.main.async { [weak self] in
            self?.run(deepLink: raw)
        }
    }

    /// 解析并执行一条深链接。认不出来的什么都不做——外部输入不猜。
    func run(deepLink raw: String) {
        guard let command = DeepLink.parse(raw) else {
            Diagnostics.log("深链接：认不出 \(raw)，已忽略")
            return
        }
        Diagnostics.log("深链接：执行 \(command)")
        let store = controller.store
        switch command {
        case .show:
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        case .refresh:
            controller.refreshNow()
        case .mountAll:
            store.mountAll()
        case .unmountAll:
            store.unmountAll()
        case .mount(let id):
            guard let drive = store.drive(id: id) else { return }
            store.mount(drive)
        case .unmount(let id):
            guard let drive = store.drive(id: id) else { return }
            store.unmount(drive)
        case .reconnect(let id):
            guard let drive = store.drive(id: id) else { return }
            store.reconnectNow(drive)
        }
    }

    /// 磁盘 › 检查所有连接：立刻跑一轮健康检查，掉了的马上重连
    @objc func checkConnections() {
        controller.store.watchdog.checkNow()
        controller.store.show("正在检查所有连接…")
    }

    @objc func addDrive() {
        controller.openAddSheet()
    }

    @objc func importMounted() {
        controller.scanMounted()
    }

    /// 磁盘 › 清理重复挂载：同一块共享挂了两份时，只留系统标准位置那一个
    @objc func cleanDuplicates() {
        controller.store.reconcileMounts(announce: true)
    }

    @objc func showManual() {
        controller.openManual()
    }

    @objc func showSettings() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.openSettings()
    }

    // MARK: - 菜单

    private func buildMenu() {
        let mainMenu = NSMenu()

        // 应用菜单
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 KesonMount",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 KesonMount",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 KesonMount",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu

        // 编辑菜单（WebView 里的输入框要靠它才能用 ⌘C/⌘V）
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        // 操作菜单
        let actionItem = NSMenuItem()
        mainMenu.addItem(actionItem)
        let actionMenu = NSMenu(title: "磁盘")

        let addItem = NSMenuItem(title: "添加网盘…", action: #selector(addDrive), keyEquivalent: "n")
        addItem.target = self
        actionMenu.addItem(addItem)

        let importItem = NSMenuItem(title: "扫描已挂载", action: #selector(importMounted), keyEquivalent: "i")
        importItem.keyEquivalentModifierMask = [.command, .shift]
        importItem.target = self
        actionMenu.addItem(importItem)

        let dedupeItem = NSMenuItem(title: "清理重复挂载", action: #selector(cleanDuplicates), keyEquivalent: "")
        dedupeItem.target = self
        actionMenu.addItem(dedupeItem)

        actionMenu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "刷新状态", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        actionMenu.addItem(refreshItem)

        let checkItem = NSMenuItem(title: "检查所有连接", action: #selector(checkConnections), keyEquivalent: "")
        checkItem.target = self
        actionMenu.addItem(checkItem)

        actionItem.submenu = actionMenu

        // 窗口菜单
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化",
                           action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放",
                           action: #selector(NSWindow.performZoom(_:)),
                           keyEquivalent: "")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        // 帮助菜单
        let helpItem = NSMenuItem()
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "帮助")
        let manualItem = NSMenuItem(title: "使用说明书", action: #selector(showManual), keyEquivalent: "?")
        manualItem.target = self
        helpMenu.addItem(manualItem)
        helpItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }
}

// MARK: - 入口

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// 隐身调试模式必须是 .accessory；正常模式下按用户的「隐藏程序坞」设置来
if AppDelegate.isHeadless {
    application.setActivationPolicy(.accessory)
} else {
    application.setActivationPolicy(AppSettings.shared.hideDockIcon ? .accessory : .regular)
}
application.run()
