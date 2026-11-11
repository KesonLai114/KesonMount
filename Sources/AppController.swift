import AppKit
import WebKit
import ServiceManagement
import UniformTypeIdentifiers

/// WKUserContentController 对 message handler 是**强引用**，而 handler 往往又持有
/// WKWebView（webView → configuration → userContentController → handler → webView）。
/// 直接注册 self 会形成解不开的环，控制器和整个页面都释放不掉。
/// 用一个只持弱引用的转发对象把环断开；AppController 自己强持有这个转发对象。
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    init(_ delegate: WKScriptMessageHandler) { self.delegate = delegate }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

final class AppController: NSObject, WKScriptMessageHandler {

    let webView: WKWebView
    let store = DriveStore()
    private var ready = false
    private var ticker: Timer?
    private var messageProxy: WeakScriptMessageHandler?
    /// 局域网发现结果
    private var discovered: [[String: Any]] = []
    private var discovering = false
    /// 发现阶段："" 结束 / "bonjour" 广播搜索 / "subnet" 网段扫描
    private var discoveringPhase = ""
    /// 每开始一轮发现就自增。异步回调（Bonjour / 网段扫描 / 补 IP / 列共享）
    /// 全部带回自己的代次，旧代次的结果直接丢弃，避免连点两次后结果串台、
    /// 或者已经清空列表又被上一轮回调写回来。
    private var discoveryGeneration = 0

    override init() {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        config.userContentController = controller
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1020, height: 720), configuration: config)
        super.init()

        let proxy = WeakScriptMessageHandler(self)
        messageProxy = proxy
        controller.add(proxy, name: "app")
        webView.underPageBackgroundColor = NSColor.windowBackgroundColor
        webView.allowsBackForwardNavigationGestures = false

        store.onChange = { [weak self] in self?.pushState() }

        // 菜单栏图标点了「添加网盘…」
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenAddSheet),
            name: .netMountOpenAddSheet,
            object: nil
        )
        // 菜单栏图标右键菜单点了「偏好设置…」
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenSettings),
            name: .netMountOpenSettings,
            object: nil
        )
        AppSettings.shared.onChange = { [weak self] in self?.pushState() }

        // 网络环境变化（换 Wi-Fi / 重连）→ 刷新界面上的 Wi-Fi 名称与提示
        NotificationCenter.default.addObserver(
            forName: .netMountNetworkChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.pushState()
        }
    }

    deinit {
        ticker?.invalidate()
        // 显式摘掉 message handler：即使 WebKit 那边还留着强引用也不会挂到已释放的控制器
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "app")
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 启动

    func start() {
        // 诊断用：不依赖界面，启动就扫描
        if ProcessInfo.processInfo.environment["NETMOUNT_LANPROBE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.startDiscovery()
            }
        }

        guard let url = Bundle.main.url(forResource: "ui", withExtension: "html"),
              let html = try? String(contentsOf: url, encoding: .utf8) else {
            webView.loadHTMLString("<h1 style='font-family:-apple-system;padding:40px'>界面文件缺失</h1>", baseURL: nil)
            return
        }
        webView.loadHTMLString(html, baseURL: nil)

        // 手动加到 .common：scheduledTimer 只注册在 .default，用户按住菜单栏菜单、
        // 拖拽窗口或弹窗处于事件跟踪模式时 RunLoop 会停掉刷新，状态看起来像卡死。
        // 这里不用 scheduledTimer，避免同一个 timer 同时挂两个 mode。
        let t = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            // SSID 在后台刷新（10 秒节流），snapshot 只读缓存，不会卡主线程
            NetworkContext.refreshAsync()
            self?.store.refresh()
        }
        ticker = t
        RunLoop.main.add(t, forMode: .common)

        // 启动时把标记了自动挂载的磁盘连上
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.store.autoMountOnLaunch()
        }

        // 调试用：设置 NETMOUNT_SNAPSHOT=<路径> 可截取界面图
        if let path = ProcessInfo.processInfo.environment["NETMOUNT_SNAPSHOT"] {
            let env = ProcessInfo.processInfo.environment
            let script = env["NETMOUNT_SNAPSHOT_JS"]
            let delay = Double(env["NETMOUNT_SNAPSHOT_DELAY"] ?? "") ?? 2.2
            // 脚本可以比截图早跑（等异步结果时用），不设就跟着截图一起跑
            let jsDelay = Double(env["NETMOUNT_SNAPSHOT_JS_DELAY"] ?? "") ?? max(0, delay - 0.8)

            func shoot() {
                snapshot(to: path)
            }

            if let script, !script.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + jsDelay) { [weak self] in
                    guard let self else { return }
                    self.log("执行截图脚本（+\(jsDelay)s）")
                    self.webView.evaluateJavaScript(script) { [weak self] res, err in
                        guard let self else { return }
                        if let err {
                            self.log("截图脚本报错：\(err.localizedDescription)")
                        } else {
                            self.log("截图脚本结果：\(res.map { "\($0)" } ?? "nil")")
                        }
                        let wait = max(0, delay - jsDelay)
                        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                            guard let self else { return }
                            self.snapshot(to: path)
                        }
                    }
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { shoot() }
            }
        }
    }

    private func snapshot(to path: String) {
        // takeSnapshot 不跑动画：弹窗的 fade-in 会停在第 0 帧（全透明），
        // 截出来就是「弹窗没出现」。截图前先把动画/过渡全关掉。
        let freeze = """
        (function(){
          var s = document.createElement('style');
          s.textContent = '*{animation:none!important;transition:none!important;}' +
                          '.spin{animation:none!important;}';
          document.head.appendChild(s);
        })();
        """
        webView.evaluateJavaScript(freeze) { [weak self] _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self?.takeShot(to: path)
            }
        }
    }

    private func takeShot(to path: String) {
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        webView.takeSnapshot(with: config) { image, _ in
            guard let image,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: URL(fileURLWithPath: path))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.terminate(nil)
            }
        }
    }

    func refreshNow() {
        store.refresh()
        pushState()
    }

    /// 菜单「添加网盘…」⌘N：打开界面上的添加弹窗
    func openAddSheet() {
        webView.evaluateJavaScript("openEditor(null)", completionHandler: nil)
    }

    /// 菜单「设置…」⌘,：打开界面上的设置面板
    func openSettings() {
        webView.evaluateJavaScript("openSettings()", completionHandler: nil)
    }

    /// 菜单栏图标点了「添加网盘…」：先把窗口弄出来，再弹添加表单
    @objc private func handleOpenAddSheet() {
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        openAddSheet()
    }

    /// 菜单栏图标右键「偏好设置…」：把窗口弄到前台并打开设置面板
    @objc private func handleOpenSettings() {
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    /// 菜单「扫描已挂载」⌘⇧I：把系统里已挂载的网络磁盘收进来
    func scanMounted() {
        webView.evaluateJavaScript("call('import')", completionHandler: nil)
    }

    /// 菜单「使用说明书」：打开随包内置的 PDF
    func openManual() {
        guard let url = Bundle.main.url(forResource: "使用说明书", withExtension: "pdf") else {
            let alert = NSAlert()
            alert.messageText = "找不到使用说明书"
            alert.informativeText = "安装包里应该带了一份 PDF，也可以在项目 docs/ 目录下找到。"
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 向前端推送状态

    private func pushState() {
        guard ready else { return }
        var snapshot = store.snapshot()
        snapshot["discovering"] = discovering
        snapshot["discoverPhase"] = discoveringPhase
        snapshot["discovered"] = discovered
        snapshot["settings"] = [
            "hideDock": AppSettings.shared.hideDockIcon,
            "showStatusBar": AppSettings.shared.showStatusBarIcon,
            "launchAtLogin": AppSettings.shared.launchAtLogin,
            "launchHint": AppSettings.shared.launchAtLoginHint,
            "watchdog": AppSettings.shared.watchdogEnabled,
            "notifyEvents": AppSettings.shared.notifyEvents,
            "closeMinimizes": AppSettings.shared.closeMinimizes,
            "globalHotkeys": AppSettings.shared.globalHotkeysEnabled
        ]
        if ProcessInfo.processInfo.environment["NETMOUNT_LOG"] == "1" {
            let s = snapshot["settings"] as? [String: Any] ?? [:]
            FileHandle.standardError.write(
                "[设置] hideDock=\(s["hideDock"] ?? "?") statusBar=\(s["showStatusBar"] ?? "?") login=\(s["launchAtLogin"] ?? "?") status=\(SMAppService.mainApp.status.rawValue)\n"
                    .data(using: .utf8)!
            )
        }
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot, options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        // JSON 合法的行/段分隔符（U+2028 / U+2029）在 2019 年前的 JS 引擎里
        // 不是合法的字符串字面量字符，会让整句 evaluateJavaScript 抛出 SyntaxError、
        // 界面整个起不来。统一转义掉再注入。
        let safe = json.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                          .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        webView.evaluateJavaScript("window.__apply(\(safe))", completionHandler: nil)
    }

    // MARK: - 局域网发现

    private let logStart = Date()

    private func log(_ m: String) {
        // 发现结果里可能带主机名 / IP，统一走 Diagnostics 做一次脱敏并留档，
        // 这样「明明扫到了却加不上」这类问题事后能导出来看，不必靠环境变量复现。
        Diagnostics.log("[LAN] \(m)")
        guard ProcessInfo.processInfo.environment["NETMOUNT_LOG"] == "1" else { return }
        let t = String(format: "%.2f", Date().timeIntervalSince(logStart))
        FileHandle.standardError.write("[LAN +\(t)s] \(m)\n".data(using: .utf8)!)
    }

    private func discoveredDict(_ h: DiscoveredHost, shares: [String] = []) -> [String: Any] {
        var dict: [String: Any] = [
            "name": h.name,
            "host": h.host,
            "proto": h.proto.rawValue,
            "protoTitle": h.proto.title,
            "address": h.address
        ]
        if let ip = h.ip { dict["ip"] = ip }
        // 不塞空数组：前端靠「有没有 shares 键」区分"还没读到"和"读到了但为空"
        if !shares.isEmpty { dict["shares"] = shares }
        return dict
    }

    func startDiscovery() {
        // WebKit 的消息回调不保证在主线程，统一拽回主线程再动 UI 状态
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.startDiscovery() }
            return
        }
        guard !discovering else { return }
        discoveryGeneration += 1
        let generation = discoveryGeneration
        discovering = true
        discoveringPhase = "bonjour"
        discovered = []
        pushState()
        log("startDiscovery 开始 main=\(Thread.isMainThread) gen=\(generation)")

        // 6 秒：实测极空间响应要 2.6s，留点余量
        let secs = Double(ProcessInfo.processInfo.environment["NETMOUNT_LAN_SECS"] ?? "") ?? 6.0
        LANDiscovery.scan(duration: secs) { [weak self] partial in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.discoveryGeneration == generation else { return }
                self.discovered = partial.map { self.discoveredDict($0) }
                self.pushState()
            }
        } onDone: { [weak self] final in
            guard let self else { return }
            self.log("Bonjour 结束，收到 \(final.count) 台")
            DispatchQueue.main.async { [weak self] in
                guard let self, self.discoveryGeneration == generation else { return }
                if !final.isEmpty {
                    self.finishDiscovery(final, generation: generation)
                    return
                }
                // Bonjour 一台没扫到 → 扫网段兜底
                self.log("Bonjour 为空，转网段扫描，本网段=\(LANDiscovery.localSubnets())")
                self.discoveringPhase = "subnet"
                self.pushState()
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let ips = LANDiscovery.scanSubnet()
                    self?.log("网段扫描命中 \(ips.count) 个 IP：\(ips.joined(separator: ","))")
                    var hosts: [DiscoveredHost] = []
                    for ip in ips {
                        let name = LANDiscovery.reverseName(ip) ?? ip
                        let shares = LANDiscovery.listShares(host: ip)
                        var h = DiscoveredHost(name: name, host: ip, proto: .smb, ip: ip)
                        h.shares = shares
                        hosts.append(h)
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.discoveryGeneration == generation else { return }
                        self.finishDiscovery(hosts, generation: generation)
                    }
                }
            }
        }
    }

    /// 发现流程收尾（主线程）
    private func finishDiscovery(_ hosts: [DiscoveredHost], generation: Int) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.finishDiscovery(hosts, generation: generation)
            }
            return
        }
        guard discoveryGeneration == generation else { return }
        discovering = false
        discoveringPhase = ""
        discovered = hosts.map { discoveredDict($0, shares: $0.shares) }
        if hosts.isEmpty {
            store.show("没发现网络磁盘。若系统问过「本地网络」权限，请到 系统设置 › 隐私与安全性 › 本地网络 里允许本应用")
        } else {
            store.show("发现 \(hosts.count) 台设备")
        }
        pushState()
        enrichDiscovered(generation: generation)
    }

    /// 后台补 IP 与共享列表（这两件事都慢，不能卡界面）
    private func enrichDiscovered(generation: Int) {
        let hosts = discovered.compactMap { $0["host"] as? String }
        guard !hosts.isEmpty else { return }
        // 已经在主线程算好：哪些设备连共享列表都有了（网段扫描那条路会顺手填）
        let readyHosts = Set(discovered.compactMap { d -> String? in
            guard d["shares"] != nil else { return nil }
            return d["host"] as? String
        })

        for host in hosts {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                // IP：挂载时用得上，快一个数量级
                if let ip = LANDiscovery.resolveIP(host) {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.discoveryGeneration == generation else { return }
                        for i in self.discovered.indices where self.discovered[i]["host"] as? String == host {
                            self.discovered[i]["ip"] = ip
                        }
                        self.pushState()
                    }
                }
                // 共享列表：网段扫描那条路已经顺手填好了，别重复拉一遍
                if readyHosts.contains(host) { return }
                let shares = LANDiscovery.listShares(host: host)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.discoveryGeneration == generation else { return }
                    for i in self.discovered.indices where self.discovered[i]["host"] as? String == host {
                        self.discovered[i]["shares"] = shares
                    }
                    self.pushState()
                }
            }
        }
    }

    /// 展开某台设备，列出它上面的共享文件夹
    func loadShares(host: String) {
        let generation = discoveryGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let shares = LANDiscovery.listShares(host: host)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.discoveryGeneration == generation else { return }
                for i in self.discovered.indices {
                    guard self.discovered[i]["host"] as? String == host else { continue }
                    self.discovered[i]["shares"] = shares
                }
                if shares.isEmpty {
                    self.store.show("没能列出共享，可能需要在服务器上开启匿名浏览")
                }
                self.pushState()
            }
        }
    }

    /// 跳到「系统设置 › 隐私与安全性 › 本地网络」
    ///
    /// Bonjour 浏览需要这个权限。用户一旦在系统弹窗里点了「不允许」，
    /// NWBrowser 会一直停在 ready 却永远收不到结果——界面看着像在搜，其实搜不到。
    func openLocalNetworkSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
        ]
        for s in urls {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    /// 从发现结果一键添加
    func quickAdd(host: String, share: String, proto: String, name: String, ip: String? = nil) {
        var drive = Drive()
        drive.name = name.isEmpty ? share : name
        drive.proto = DiskProtocol(rawValue: proto) ?? .smb
        drive.host = Drive.normalizeHost(host)
        drive.ipHint = (ip?.isEmpty == false) ? ip : nil
        drive.share = share
        drive.imported = true
        drive.note = "从局域网发现添加"
        store.upsert(drive, password: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.store.mount(drive)
        }
    }

    // MARK: - 接收前端指令

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        // WKScriptMessageHandler 的回调线程不保证在主线程，
        // 而里面会动 UI（NSAlert / NSWorkspace.open / setActivationPolicy 等），
        // 统一拽回主线程再处理，避免偶发的非主线程 UI 操作
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handleMessage(action: action, body: body)
            }
            return
        }
        handleMessage(action: action, body: body)
    }

    private func handleMessage(action: String, body: [String: Any]) {
        switch action {
        case "ready":
            ready = true
            pushState()

        case "refresh":
            store.refresh()
            pushState()

        case "import":
            store.importMountedDrives()
            pushState()

        case "discover":
            startDiscovery()

        case "openPrivacy":
            openLocalNetworkSettings()

        // 界面上的设置开关：开机启动 / 程序坞图标 / 菜单栏图标 / 自动重挂 / 通知
        case "setSetting":
            guard let key = body["key"] as? String,
                  let value = body["value"] as? Bool else { return }
            switch key {
            case "hideDock":
                AppSettings.shared.hideDockIcon = value
                store.show(value ? "已隐藏程序坞图标，用菜单栏图标打开" : "已恢复程序坞图标")
            case "showStatusBar":
                AppSettings.shared.showStatusBarIcon = value
                NotificationCenter.default.post(name: .netMountRefreshStatusBar, object: nil)
                store.show(value ? "已显示菜单栏图标" : "已隐藏菜单栏图标")
            case "launchAtLogin":
                if let err = AppSettings.shared.setLaunchAtLogin(value) {
                    store.show(err)
                } else {
                    store.show(value ? "已开启开机启动" : "已关闭开机启动")
                }
            case "watchdog":
                AppSettings.shared.watchdogEnabled = value
                store.watchdog.restartIfNeeded()
                store.show(value ? "已开启掉线自动重挂" : "已关闭掉线自动重挂")
            case "notifyEvents":
                AppSettings.shared.notifyEvents = value
                store.show(value ? "掉线与重连时会发系统通知" : "不再发系统通知")
            case "closeMinimizes":
                AppSettings.shared.closeMinimizes = value
                store.show(value ? "关闭主窗口将最小化到后台" : "关闭主窗口将直接退出")
            case "globalHotkeys":
                AppSettings.shared.globalHotkeysEnabled = value
                if value {
                    // 全局快捷键要「辅助功能」权限，没有就明确引导用户去开
                    if !HotkeyManager.shared.requestPermission() {
                        store.show("请在「系统设置 › 隐私与安全性 › 辅助功能」里允许网盘管家")
                    } else {
                        store.show("已开启全局快捷键")
                    }
                } else {
                    store.show("已关闭全局快捷键")
                }
                NotificationCenter.default.post(name: .netMountRefreshHotkeys, object: nil)
            default:
                return
            }
            pushState()

        case "diagnose":
            if let drive = drive(from: body) {
                store.diagnose(drive)
                pushState()
            }

        case "listShares":
            if let host = body["host"] as? String { loadShares(host: host) }

        case "quickAdd":
            guard let host = body["host"] as? String,
                  let share = body["share"] as? String else { return }
            quickAdd(host: host,
                     share: share,
                     proto: body["proto"] as? String ?? "smb",
                     name: body["name"] as? String ?? "",
                     ip: body["ip"] as? String)

        case "toggle":
            if let drive = drive(from: body) { store.toggleMount(drive) }

        case "mount":
            if let drive = drive(from: body) { store.mount(drive) }

        case "unmount":
            if let drive = drive(from: body) { store.unmount(drive) }

        // 主窗口 / 面板上的「挂载全部 / 卸载全部」
        case "mountAll":
            store.mountAll()
        case "unmountAll":
            store.unmountAll()

        // 配置备份：导出 / 导入（密码存在钥匙串，不进文件）
        case "exportConfig":
            exportConfig()
        case "importConfig":
            importConfig()

        // 运行期诊断报告（设置面板里一键导出，全文自动脱敏）
        case "exportDiagnostics":
            exportDiagnostics()

        // 清除这块盘保存在钥匙串里的密码（不改服务器地址等其他配置）
        case "clearPassword":
            guard let id = body["id"] as? String, let uuid = UUID(uuidString: id) else { return }
            store.clearPassword(for: uuid)
            pushState()

        case "reveal":
            if let drive = drive(from: body) {
                NSWorkspace.shared.open(URL(fileURLWithPath: store.revealPath(for: drive)))
            }

        case "copy":
            if let drive = drive(from: body) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(drive.address, forType: .string)
                store.show("地址已复制：\(drive.address)")
                pushState()
            }

        case "autoMount":
            if let drive = drive(from: body) { store.toggleAutoMount(drive) }

        case "toggleRemount":
            if let drive = drive(from: body) { store.toggleAutoRemount(drive) }

        case "reconnectNow":
            if let drive = drive(from: body) { store.reconnectNow(drive) }

        case "remove":
            if let drive = drive(from: body) { store.remove(drive) }

        case "save":
            guard let dict = body["drive"] as? [String: Any] else { return }
            let password = body["password"] as? String
            // 校验失败给出人话提示（driveFromDict 内部也拦一道）
            if let reason = invalidSaveReason(dict) {
                store.show(reason)
                return
            }
            guard var drive = driveFromDict(dict) else {
                store.show("保存失败：请检查表单里的服务器地址和共享名")
                return
            }
            let isNew = store.drive(id: drive.id) == nil
            drive.note = store.drive(id: drive.id)?.note ?? drive.note
            store.upsert(drive, password: password)
            // 新添加的磁盘直接尝试连一次，省得再点一下「挂载」
            if isNew {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.store.mount(drive)
                }
            }

        default:
            break
        }
    }

    // MARK: - 配置备份 / 恢复

    /// 导出运行期诊断报告。只写配置摘要与决策日志，密码 / 连接串一律不落盘。
    private func exportDiagnostics() {
        let drives = store.snapshot()["drives"] as? [[String: Any]] ?? []
        let summary: [String] = drives.map { d in
            let name = d["name"] as? String ?? "?"
            let proto = d["proto"] as? String ?? "?"
            let host = d["host"] as? String ?? "?"
            let share = d["share"] as? String ?? "?"
            let port = d["port"] as? Int ?? 0
            let flags = [
                "autoMount=\((d["autoMount"] as? Bool ?? false) ? "1" : "0")",
                "autoRemount=\((d["autoRemount"] as? Bool ?? true) ? "1" : "0")",
                "readOnly=\((d["readOnly"] as? Bool ?? false) ? "1" : "0")",
                "mounted=\((d["mounted"] as? Bool ?? false) ? "1" : "0")"
            ].joined(separator: " ")
            return "- \(name) [\(proto)] \(host):\(port)/\(share) \(flags)"
        }
        let text = MountService.redact(Diagnostics.exportText(driveSummary: summary))
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "网盘管家诊断-\(AppInfo.version).txt"
        panel.allowedContentTypes = [UTType.plainText]
        panel.canCreateDirectories = true
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                self?.store.show("诊断报告已导出：\(url.lastPathComponent)")
            } catch {
                self?.store.show("诊断导出失败：\(error.localizedDescription)")
            }
        }
    }

    /// 把磁盘配置导成一个 JSON 文件（备份 / 换机）。前置保存面板让用户挑位置。
    private func exportConfig() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "网盘管家配置-\(AppInfo.version).json"
        panel.allowedContentTypes = [UTType.json]
        panel.canCreateDirectories = true
        panel.begin { [weak self] resp in
            guard let self else { return }
            guard resp == .OK, let url = panel.url else { return }
            do {
                let n = try self.store.exportConfig(to: url)
                self.store.show("已导出 \(n) 块磁盘的配置到：\(url.lastPathComponent)")
                self.pushState()
            } catch {
                self.store.show("导出失败：\(error.localizedDescription)")
            }
        }
    }

    /// 从 JSON 备份导入配置（按 id 合并，不整份替换）。
    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] resp in
            guard let self else { return }
            guard resp == .OK, let url = panel.url else { return }
            do {
                let (added, updated) = try self.store.importConfig(from: url)
                self.store.show("已导入配置：新增 \(added) 块、更新 \(updated) 块")
                self.pushState()
            } catch {
                self.store.show("导入失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 参数解析

    private func drive(from body: [String: Any]) -> Drive? {
        guard let idString = body["id"] as? String, let id = UUID(uuidString: idString) else { return nil }
        return store.drive(id: id)
    }

    /// 保存前的轻量校验：返回提示文案表示不通过，nil 表示 OK。
    /// 与 driveFromDict 共享逻辑，但只判错不构造 Drive。
    private func invalidSaveReason(_ dict: [String: Any]) -> String? {
        let name = (dict["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let host = (dict["host"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let share = (dict["share"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let user = (dict["username"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let proto = dict["proto"] as? String
        let mount = (dict["mountPoint"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "请填写磁盘名称" }
        if host.isEmpty { return "请填写服务器地址" }
        if share.isEmpty, proto != "nfs" { return "请填写共享名或路径" }
        // 用户名会原样拼进 URL 的 userinfo 段，也会显示在界面 / 写进配置备份。
        // 带冒号就变成 user:password，容易被误当成「密码写进了用户名」泄漏出去。
        if user.contains(":") {
            return "用户名里不能带冒号；密码请填在下面的密码栏"
        }
        if !Drive.isSafeMountPoint(mount) {
            return "挂载点不合法：只能是 /Volumes/<名称>（留空即用默认位置）"
        }
        return nil
    }

    private func driveFromDict(_ dict: [String: Any]) -> Drive? {
        guard invalidSaveReason(dict) == nil else { return nil }
        var drive = Drive()
        if let s = dict["id"] as? String, let id = UUID(uuidString: s), let existing = store.drive(id: id) {
            drive = existing
        } else {
            drive.createdAt = Date()
        }
        drive.name = (dict["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        drive.proto = DiskProtocol(rawValue: dict["proto"] as? String ?? "smb") ?? .smb
        let rawHost = dict["host"] as? String ?? ""
        let split = Drive.splitHostPort(rawHost)
        drive.host = split.host
        drive.share = (dict["share"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        drive.username = (dict["username"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = dict["port"] as? Int, p > 0 {
            drive.port = p
        } else {
            drive.port = split.port
        }
        drive.mountPoint = (dict["mountPoint"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        drive.autoMount = dict["autoMount"] as? Bool ?? false
        drive.autoRemount = dict["autoRemount"] as? Bool ?? true
        drive.smbVersion = SMBVersion.from(raw: dict["smbVersion"] as? String)
        drive.readOnly = dict["readOnly"] as? Bool ?? false
        // 缺省 true：老版本前端 / 老配置不会带这个键，保持原来的 HTTPS 行为
        drive.webdavSecure = dict["webdavSecure"] as? Bool ?? true
        // 网络唤醒用的 MAC（已挂载状态也能看到）：空串表示不填
        let rawMac = (dict["macAddress"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        drive.macAddress = rawMac.isEmpty ? nil : Drive.normalizeMAC(rawMac)
        // 只在指定 Wi-Fi 下自动挂载（编辑时总会带这个数组，可能为空）
        drive.allowedSSIDs = (dict["allowedSSIDs"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return drive
    }
}
