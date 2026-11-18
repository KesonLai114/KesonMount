import AppKit

/// 菜单栏（通知栏）图标 + 快捷菜单。
///
/// 用户主要在三种时候用它：
///   1. 程序坞图标隐藏了 —— 这是唯一入口
///   2. 不想翻窗口，快速挂载 / 卸载全部
///   3. 切换开机启动、程序坞图标这些开关
final class StatusBarController: NSObject {

    private var statusItem: NSStatusItem?
    private weak var store: DriveStore?
    private var windowProvider: (() -> NSWindow?)?

    /// 左键弹出的面板：不用切主窗口也能看状态、顺手挂/卸
    private var popover: NSPopover?
    private var popoverVC: StatusPopoverController?

    /// 菜单每次打开前重建，勾选状态和磁盘摘要才是最新的
    private lazy var menu = NSMenu()

    // MARK: - 安装 / 移除

    func install(store: DriveStore, windowProvider: @escaping () -> NSWindow?) {
        self.store = store
        self.windowProvider = windowProvider

        // AppSettings 只有一个 onChange 槽位，先接上前一个（AppController 要靠它刷新界面），
        // 否则这边一赋值就把界面刷新给顶掉了
        let previous = AppSettings.shared.onChange
        AppSettings.shared.onChange = { [weak self] in
            previous?()
            DispatchQueue.main.async { self?.refreshVisibility() }
        }
        // 界面上的开关也要能同步菜单栏图标的显隐
        NotificationCenter.default.addObserver(
            forName: .netMountRefreshStatusBar,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshVisibility()
        }
        refreshVisibility()
    }

    /// 按设置决定要不要显示菜单栏图标
    func refreshVisibility() {
        if AppSettings.shared.showStatusBarIcon {
            if statusItem == nil { buildStatusItem() }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "externaldrive.connected.to.line.below",
                accessibilityDescription: "KesonMount"
            )
            button.image?.isTemplate = true          // 自动适配深浅色菜单栏
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        // 关键：不要设置 item.menu。一旦设了 menu，点图标会直接弹菜单，
        // 左键弹面板（popover）的 action 根本不会被调用。这里全交给 action，
        // 右键时再手动 popUpMenu(menu)。
        menu.delegate = self
        buildPopover()
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        // 左键弹面板（菜单栏 App 的主战场，不切窗口也能干活）；
        // 右键（或 Ctrl+左键，老 Mac 习惯）才弹完整菜单。
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            statusItem?.popUpMenu(menu)
        } else {
            togglePopover(sender)
        }
    }

    // MARK: - 面板（左键）

    private func buildPopover() {
        guard let store else { return }
        let vc = StatusPopoverController(store: store)
        vc.onOpenWindow = { [weak self] in self?.showMainWindow() }
        vc.onOpenSettings = { [weak self] in self?.openSettings() }
        vc.onMountAll = { [weak self] in self?.mountAll() }
        vc.onUnmountAll = { [weak self] in self?.unmountAll() }
        // 磁盘数量变了，面板高度要跟着变（contentSize 建好之后不会自己动）
        vc.onResize = { [weak self] size in
            self?.popover?.contentSize = size
        }
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.contentSize = NSSize(width: StatusPopoverController.panelWidth, height: vc.preferredHeight)
        pop.behavior = .transient
        pop.delegate = self
        popover = pop
        popoverVC = vc
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let pop = popover else { showMainWindow(); return }
        if pop.isShown {
            pop.performClose(sender)
        } else if let button = statusItem?.button {
            // 主窗口藏着的时候后台刷新只有 30 秒一次的慢节奏，
            // 面板一打开就得先把状态拉新，不然第一眼看到的是半分钟前的旧数据
            store?.refresh()
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popoverVC?.startRefresh()
        }
    }

    // MARK: - 动作

    @objc func showMainWindow() {
        guard let window = windowProvider?() else { return }
        window.makeKeyAndOrderFront(nil)
        // 隐藏程序坞时激活策略是 .accessory，仍需显式激活才能拿焦点
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 右键菜单「偏好设置…」：先把窗口弄出来，再让前端打开设置面板
    @objc func openSettings() {
        showMainWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: .netMountOpenSettings, object: nil)
        }
    }

    @objc func mountAll() {
        guard let store else { return }
        let pending = store.drives.filter { store.volume(for: $0) == nil }
        guard !pending.isEmpty else {
            store.show("全部磁盘都已挂载")
            return
        }
        for drive in pending { store.mount(drive) }
    }

    @objc func unmountAll() {
        guard let store else { return }
        let mounted = store.drives.filter { store.volume(for: $0) != nil }
        guard !mounted.isEmpty else {
            store.show("当前没有已挂载的磁盘")
            return
        }
        for drive in mounted { store.unmount(drive) }
    }

    @objc func scanMounted() {
        store?.importMountedDrives()
    }

    /// 手动跑一轮健康检查：掉了的立刻重连，不用等下一个 30 秒
    @objc func checkConnections() {
        guard let store else { return }
        store.watchdog.checkNow()
        store.show("正在检查所有连接…")
    }

    @objc func addDrive() {
        showMainWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: .netMountOpenAddSheet, object: nil)
        }
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}

extension Notification.Name {
    static let netMountOpenAddSheet = Notification.Name("netMountOpenAddSheet")
    static let netMountRefreshStatusBar = Notification.Name("netMountRefreshStatusBar")
    static let netMountOpenSettings = Notification.Name("netMountOpenSettings")
    static let netMountRefreshHotkeys = Notification.Name("netMountRefreshHotkeys")
}

// MARK: - 面板关闭时停掉定时刷新

extension StatusBarController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        popoverVC?.stopRefresh()
    }
}

// MARK: - 菜单内容

extension StatusBarController: NSMenuDelegate {

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let drives = store?.drives ?? []
        let mountedCount = drives.filter { store?.volume(for: $0) != nil }.count

        // 摘要：一眼看到几块盘挂着
        let summary = NSMenuItem(
            title: mountedCount == 0 && drives.isEmpty
                ? "还没有网络磁盘"
                : "已挂载 \(mountedCount) / 共 \(drives.count) 块",
            action: nil,
            keyEquivalent: ""
        )
        summary.isEnabled = false
        summary.image = img("network")
        menu.addItem(summary)
        menu.addItem(.separator())

        menu.addItem(item("打开KesonMount", action: #selector(showMainWindow), key: "o", symbol: "macwindow"))
        menu.addItem(item("偏好设置…", action: #selector(openSettings), key: "", symbol: "gearshape"))
        menu.addItem(.separator())

        let mountAll = NSMenuItem(
            title: "挂载全部",
            action: #selector(mountAll),
            keyEquivalent: ""
        )
        mountAll.image = img("plus.circle")
        mountAll.isEnabled = mountedCount < drives.count
        menu.addItem(mountAll)

        let unmountAll = NSMenuItem(
            title: "卸载全部",
            action: #selector(unmountAll),
            keyEquivalent: ""
        )
        unmountAll.image = img("minus.circle")
        unmountAll.isEnabled = mountedCount > 0
        menu.addItem(unmountAll)

        menu.addItem(.separator())

        // 每块盘一个入口：已挂载的点了卸载，未挂载的点了挂载
        for drive in drives {
            let isMounted = store?.volume(for: drive) != nil
            let it = NSMenuItem(
                title: "\(drive.name)　\(isMounted ? "卸载" : "挂载")",
                action: isMounted ? #selector(unmountDrive(_:)) : #selector(mountDrive(_:)),
                keyEquivalent: ""
            )
            it.target = self
            it.representedObject = drive
            it.image = NSImage(
                systemSymbolName: isMounted
                    ? "externaldrive.fill.badge.checkmark"
                    : "externaldrive.badge.plus",
                accessibilityDescription: nil
            )
            it.image?.isTemplate = true
            menu.addItem(it)
        }

        menu.addItem(.separator())
        menu.addItem(item("扫描已挂载", action: #selector(scanMounted), key: "i", symbol: "tray.and.arrow.down"))
        menu.addItem(item("检查所有连接", action: #selector(checkConnections), key: "", symbol: "stethoscope"))
        menu.addItem(item("添加网盘…", action: #selector(addDrive), key: "n", symbol: "plus"))

        menu.addItem(.separator())

        // 开关区
        let login = NSMenuItem(
            title: "开机启动",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        login.target = self
        login.state = AppSettings.shared.launchAtLogin ? .on : .off
        login.image = img("power")
        menu.addItem(login)

        let dock = NSMenuItem(
            title: "在程序坞显示图标",
            action: #selector(toggleDockIcon),
            keyEquivalent: ""
        )
        dock.target = self
        dock.state = AppSettings.shared.hideDockIcon ? .off : .on
        dock.image = img("dock.rectangle")
        menu.addItem(dock)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出KesonMount", action: #selector(quit), keyEquivalent: "q")
        quit.image = img("arrow.right.square")
        quit.target = self
        menu.addItem(quit)

        // 所有项统一指向 self
        for it in menu.items where it.target == nil {
            it.target = self
        }
    }

    private func item(_ title: String, action: Selector, key: String, symbol: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        if !symbol.isEmpty { i.image = img(symbol) }
        return i
    }

    /// 统一取 SF Symbol 图标并标成模板（自动适配深浅色）
    private func img(_ symbol: String) -> NSImage? {
        let i = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        i?.isTemplate = true
        return i
    }

    @objc private func mountDrive(_ sender: NSMenuItem) {
        guard let drive = sender.representedObject as? Drive else { return }
        store?.mount(drive)
    }

    @objc private func unmountDrive(_ sender: NSMenuItem) {
        guard let drive = sender.representedObject as? Drive else { return }
        store?.unmount(drive)
    }

    @objc private func toggleLaunchAtLogin() {
        let on = !AppSettings.shared.launchAtLogin
        if let err = AppSettings.shared.setLaunchAtLogin(on) {
            store?.show(err)
        } else {
            store?.show(on ? "已开启开机启动" : "已关闭开机启动")
        }
        rebuildMenu()
    }

    @objc private func toggleDockIcon() {
        AppSettings.shared.hideDockIcon.toggle()
        let hidden = AppSettings.shared.hideDockIcon
        store?.show(hidden ? "已隐藏程序坞图标，用菜单栏图标打开" : "已恢复程序坞图标")
        rebuildMenu()
    }

    // MARK: - 诊断

    /// 把面板视图强行构建一遍，供自动化校验（KESONMOUNT_DUMP_POPOVER=1）：
    /// 面板是原生 NSPopover，HTML 截图拍不到，只能确认它能构建、不崩
    func dumpPopover() {
        guard let vc = popoverVC else {
            print("[面板] 未创建（可能没装菜单栏图标）")
            return
        }
        _ = vc.view          // 触发 loadView
        vc.refresh()
        print("[面板] 构建成功 · 尺寸 \(Int(vc.view.frame.width))×\(Int(vc.view.frame.height)) · 磁盘 \(store?.drives.count ?? 0) 块 · 版本 \(AppInfo.full)")
        if let path = AppEnvironment.value("SNAPSHOT_POPOVER") {
            vc.renderPNG(to: path)
            print("[面板] 已渲染 PNG：\(path)")
        }
    }

    /// 把菜单内容打到标准输出，供自动化校验（KESONMOUNT_DUMP_STATUSBAR=1）
    func dumpMenu() {
        rebuildMenu()
        print("[菜单栏图标] 共 \(menu.items.count) 项")
        for (i, item) in menu.items.enumerated() {
            if item.isSeparatorItem {
                print("  \(i + 1). ──────")
                continue
            }
            let mark = item.state == .on ? "☑" : "☐"
            let enabled = item.isEnabled ? "" : "（不可点）"
            let obj = (item.representedObject as? Drive)?.name ?? ""
            // ▣ 有图标 / ▢ 没图标：右键菜单一致性（每项都要有图标）靠这个自检
            let icon = item.image != nil ? "▣" : "▢"
            print("  \(i + 1). \(icon) \(mark) \(item.title)\(obj.isEmpty ? "" : " [\(obj)]")\(enabled)")
        }
    }
}
