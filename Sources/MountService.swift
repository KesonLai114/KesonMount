import Foundation

enum OpResult {
    case ok(String)
    case fail(String)
}

/// 真正的挂载 / 卸载动作
enum MountService {

    // MARK: 挂载

    /// 挂载一块磁盘。
    /// - Parameter versionOverride: 临时指定 SMB 版本（连接诊断用），nil 表示用磁盘自己存的设置
    static func mount(_ drive: Drive, versionOverride: SMBVersion? = nil) -> OpResult {
        if let existing = MountScanner.match(drive: drive, in: MountScanner.scan()) {
            // 已经挂上了 = 唤醒/重连成功，清掉「正在唤醒」的去重标记
            MountWatchdog.clearWakeNotification(drive.id)
            return .ok("已经挂载在 \(existing.path)")
        }

        // 密码来源：KesonMount 自己存的 → 系统里（访达连过）存的 → 都不要就去问系统
        var password = Keychain.password(for: drive)
        var inheritedFromSystem = false
        if password == nil, drive.proto != .nfs {
            if let systemPassword = Keychain.systemPassword(host: drive.host, username: drive.username) {
                password = systemPassword
                inheritedFromSystem = true
                // 顺手收进自己的钥匙串，以后挂载不用再问系统
                Keychain.save(password: systemPassword, for: drive)
            }
        }

        let version = versionOverride ?? drive.smbVersion

        // 地址候选顺序：卷名就是共享名，host 只是「怎么连」，所以裸名优先、
        // .local 兜底、IP 最后兜底（双网卡 / 解析异常时保证连得上）。
        let bare = LANDiscovery.bareName(drive.host)
        var hosts: [String] = []
        // 1) 裸名 Z4S-I0C9 —— 走 NetBIOS 广播，最快最稳，卷身份也是设备名。
        if bare != drive.host, !hosts.contains(bare) { hosts.append(bare) }
        // 2) .local 形式 —— 走 mDNS 的兜底，仅当裸名解析不到时才用。
        if !hosts.contains(drive.host) { hosts.append(drive.host) }
        // 3) IP（192.168.31.4）—— 双网卡 / 解析异常时最后兜底。
        if drive.proto != .nfs {
            for ip in LANDiscovery.resolveIPs(drive.host)
                where !hosts.contains(ip) && ip != drive.host && ip != bare {
                hosts.append(ip)
            }
        }
        if let ip = drive.ipHint, !ip.isEmpty, ip != drive.host, ip != bare, !hosts.contains(ip) {
            hosts.append(ip)
        }

        var lastFailure: OpResult = .fail("挂载失败：未知原因")
        var triedWake = false
        // 端口越界会让 UInt16(...) 直接 trap。入口（Drive.init(from:)）已经过滤过，
        // 这里再用 exactly 兜一次底——任何路径进来都不应该把 App 弄崩。
        let probePort = drive.port.flatMap { UInt16(exactly: $0) }
            ?? UInt16(clamping: drive.proto.defaultPort)
        for host in hosts {
            // 先做一次主机解析，避免地址写错时白等半分钟
            if !isReachableHost(host) {
                lastFailure = .fail("找不到服务器「\(host)」。请检查地址是否正确、设备是否开机、是否和 Mac 在同一网络。")
                continue
            }
            // 配了 MAC 的盘：如果端口探不通，多半是设备睡着（或者刚重启还没起来），
            // 这时先发个魔术包把它叫醒，再挂载。
            // 注意必须探真实端口——DNS 解析对 IP 地址是恒成功的，
            // 睡着的 NAS 一样能「解析」，靠它判断会把设备睡着的假象放过去。
            if !triedWake,
               let mac = drive.macAddress, !mac.isEmpty,
               !isPortOpen(host: host, port: probePort) {
                if WakeOnLAN.send(mac: mac) {
                    // 只有魔术包真的发出去了，才算「尝试过唤醒」。
                    // MAC 写错 / 广播全失败时不能置位，否则失败提示会把排查方向带偏。
                    triedWake = true
                    MountWatchdog.notifyWakeOnce(
                        drive: drive,
                        title: "正在唤醒「\(drive.name)」",
                        body: "设备没有响应，已发送网络唤醒包（Wake-on-LAN）"
                    )
                    lastFailure = .fail("正在唤醒「\(drive.name)」…")
                    // 从休眠到启动要十几秒，边等边探
                    for _ in 0..<10 {
                        usleep(1_000_000)
                        if isPortOpen(host: host, port: probePort) { break }
                    }
                }
            }
            let r = performMount(withHost(drive, host, version: version), password: password)
            switch r {
            case .ok(let m):
                // 挂是挂上了，但得确认它真落在用户记的那个位置：同名卷已存在时，
                // 系统会自动给新卷加 -1 后缀（/Volumes/HD-1）。路径一变，用户
                // 配好的文件路径就全废了——这种情况当失败报，别让他以为挂好了。
                // 比较用标准化 + 忽略大小写：卷名实际大小写常和输入不一致，
                // 直接字符串相等会把「已经挂好」误报成「没落在预期位置」。
                if !MountScanner.scan().contains(where: { samePath($0.path, drive.resolvedMountPoint) }) {
                    let landed = MountScanner.match(drive: drive, in: MountScanner.scan())?.path
                    return .fail(
                        "挂上了，但落在 \(landed ?? "别的位置")，不是 \(drive.resolvedMountPoint)。多半是已有同名卷（系统会给新卷加 -1 后缀），请先卸载重名的那个再试"
                    )
                }
                if drive.readOnly, isReadOnlyMount(drive.resolvedMountPoint) == false {
                    // 只读必须真的只读：系统挂载器不认 rdonly 时，宁可摘掉也不能让
                    // 用户以为在用只读盘、实际却能写。
                    var unloaded = false
                    if let v = MountScanner.match(drive: drive, in: MountScanner.scan()) {
                        if case .ok = unmount(v, force: false) { unloaded = true }
                    }
                    return .fail(
                        unloaded
                            ? "系统挂载方式没有把这块盘挂成只读，已自动卸载（避免误以为只读、实际可写）。如需只读，请在 NAS 上把这个共享设为只读"
                            : "系统挂载方式没有把这块盘挂成只读，且自动卸载失败——它现在可写，请手动推出后重试"
                    )
                }
                MountWatchdog.clearWakeNotification(drive.id)
                return inheritedFromSystem ? .ok("\(m)（已自动沿用系统里保存的密码）") : .ok(m)
            case .fail:
                lastFailure = r
            }
        }
        if triedWake {
            return .fail("已尝试网络唤醒仍未连上：\(lastFailureMessage(lastFailure))")
        }
        return lastFailure
    }

    /// 把 OpResult 里的失败文案抠出来
    private static func lastFailureMessage(_ r: OpResult) -> String {
        if case .fail(let m) = r { return m }
        return "未知原因"
    }

    /// 服务器的端口是否真的开着（比 DNS 解析靠谱得多）
    private static func isPortOpen(host: String, port: UInt16) -> Bool {
        guard let ip = LANDiscovery.resolveIP(host) else { return false }
        return LANDiscovery.probeTCP(ip, port: port, timeout: 0.6)
    }

    private static func withHost(_ drive: Drive, _ host: String, version: SMBVersion) -> Drive {
        var copy = drive
        copy.host = host
        copy.smbVersion = version
        return copy
    }

    private static func performMount(_ drive: Drive, password: String?) -> OpResult {
        switch drive.proto {
        case .smb, .webdav:
            // 自定义目录只有用户态挂载器（mount_smbfs / mount_webdav）挂得进去，而它
            // 只能把账号密码拼进命令行 URL——`ps` 同机任何账号都看得到，与「密码不进
            // 进程表」的底线直接冲突。系统挂载器又只认 /Volumes/<共享名>，所以这里
            // 直接拦住让用户改回标准位置，而不是偷偷降级、把凭据漏出去。
            if !drive.mountPoint.isEmpty, !drive.mountPoint.hasPrefix("/Volumes/") {
                return .fail(
                    "挂载点只能是 /Volumes/<共享名>：自定义目录需要把密码交给命令行，出于安全考虑已取消。请把挂载点清空后重试"
                )
            }
            var failures: [String] = []
            var attempts: [() -> OpResult?] = []
            // 约定挂在 /Volumes/<共享名>——和访达挂载的位置一样。这个目录只有 NetFS
            // 写得进去，路径也才和用户在别的软件里配好的一致，所以不给别的兜底：
            // 挂不上就如实报错，绝不偷偷换位置。
            attempts.append { viaSystemMount(drive, password: password) }
            attempts.append { viaOpenURL(drive) }

            for attempt in attempts {
                guard let r = attempt() else { continue }
                switch r {
                case .ok: return r
                case .fail(let m): failures.append(m)
                }
            }
            let detail = failures.isEmpty ? "未知原因" : failures.joined(separator: "；")
            return .fail("挂载失败：\(detail)")

        case .nfs:
            // NFS 没有账号密码，走系统挂载器时不需要凭据
            if let r = viaSystemMount(drive, password: nil), case .ok = r { return r }
            // share 在保存时被剥掉了前导斜杠，拼命令时必须补回来：
            // NFS 的导出路径是绝对路径，写成 `nas:volume1/video` 照抄必失败。
            let export = drive.share.hasPrefix("/") ? drive.share : "/" + drive.share
            // 系统挂载器对 NFS 的支持很有限（`mount volume nfs://…` 常常直接不认），
            // 所以再真正调一次 `mount -t nfs`，用系统授权框提权。
            // 早先这里只是把命令打印出来让用户自己去终端敲——那等于这个功能没做完。
            if let r = viaPrivilegedNFSMount(drive, export: export) { return r }
            let manual = nfsMountCommand(host: drive.host, export: export,
                                         mountPoint: drive.resolvedMountPoint)
            return .fail("NFS 需要管理员权限，请在终端执行：\(manual)")
        }
    }

    /// NFS 挂载命令（终端版）。来自配置的 host / 导出路径 / 挂载点
    /// 必须做 shell 引号转义，否则一份伪造的配置文件就能诱导执行任意命令。
    static func nfsMountCommand(host: String, export: String, mountPoint: String) -> String {
        "sudo mount -t nfs " + shellQuote("\(host):\(export)") + " " + shellQuote(mountPoint)
    }

    /// 用系统授权框真正把 NFS 挂上。
    ///
    /// 返回 nil 表示前置条件不满足、根本没发起提权（调用方会退回「请自己执行命令」的提示）。
    /// NFS 本身不需要密码，提权只是为了 `mount` 这个动作——不会把任何凭据交给命令行。
    private static func viaPrivilegedNFSMount(_ drive: Drive, export: String) -> OpResult? {
        let mp = drive.resolvedMountPoint
        guard mp.hasPrefix("/Volumes/") else { return nil }
        // 先建目录：mount_nfs 要求挂载点已存在，而 /Volumes/<名> 未必存在
        let inner = "/bin/mkdir -p " + shellQuote(mp)
            + " && /sbin/mount -t nfs " + shellQuote("\(drive.host):\(export)")
            + " " + shellQuote(mp)
        // 内层是 shell 命令，外层是 AppleScript 字符串，两层都要转义
        let script = "do shell script \"\(appleScriptQuote(inner))\" with administrator privileges"
        let r = Shell.run("/usr/bin/osascript", ["-"], timeout: 90, input: script)
        if r.ok {
            if let v = waitForMount(drive: drive, timeout: 10) { return .ok("已挂载到 \(v.path)") }
            return .ok("已挂载")
        }
        let msg = r.message
        if msg.contains("-128") || msg.lowercased().contains("user canceled") {
            return .fail("已取消管理员授权，NFS 没有挂载")
        }
        return .fail("NFS 挂载失败：\(friendly(msg))")
    }

    // MARK: 卸载

    /// - Parameter force: 强制卸载。掉线的挂载点普通卸载会一直转圈（Device busy），
    ///   只有 `diskutil unmount force` / `umount -f` 能把它摘掉，重挂前必须先走这条。
    /// - Parameter privileged: 允许弹管理员授权框。只有用户主动点「卸载」时才传 true——
    ///   看门狗在后台自动重连时绝不能弹框，那比卸不掉更吓人。
    static func unmount(_ volume: MountedVolume, force: Bool = false,
                        privileged: Bool = false) -> OpResult {
        if force {
            let f = Shell.run("/usr/sbin/diskutil", ["unmount", "force", volume.path], timeout: 25)
            if f.ok { return unmounted(volume) }
        }

        let d = Shell.run("/usr/sbin/diskutil", ["unmount", volume.path], timeout: 25)
        if d.ok { return unmounted(volume) }

        let u = Shell.run("/sbin/umount", [volume.path], timeout: 25)
        if u.ok { return unmounted(volume) }

        if force {
            let f = Shell.run("/sbin/umount", ["-f", volume.path], timeout: 25)
            if f.ok { return unmounted(volume) }
        }

        // NFS 由 root 挂上去的卷普通用户卸不掉，只能提权。同样只在用户主动卸载时问。
        if privileged, volume.fsType == "nfs" {
            let script = "do shell script \"/sbin/umount "
                + appleScriptQuote(shellQuote(volume.path)) + "\" with administrator privileges"
            let p = Shell.run("/usr/bin/osascript", ["-"], timeout: 60, input: script)
            if p.ok { return unmounted(volume) }
            if p.message.contains("-128") || p.message.lowercased().contains("user canceled") {
                return .fail("已取消管理员授权，磁盘仍挂载着")
            }
        }

        let msg = u.message.isEmpty ? d.message : u.message
        if msg.contains("busy") || msg.contains("in use") {
            return .fail("磁盘正在被使用，请先关闭正在读写该磁盘的程序再试")
        }
        return .fail("卸载失败：\(msg.isEmpty ? "未知原因" : msg)")
    }

    /// 卸载成功后的统一收尾：顺手清掉这条路径的健康探测记录。
    /// 不清的话，重新挂到同一位置的卷会继承「上一辈子」那条卡死的探测，
    /// 被永远判成失去响应。
    private static func unmounted(_ volume: MountedVolume) -> OpResult {
        MountHealth.forget(volume.path)
        return .ok("已卸载「\(volume.shareName)」")
    }

    // MARK: 方式一：交给系统挂载器（NetFS）挂载——和访达里手动连接是同一条路

    /// 用 `mount volume` 挂载，最终落在 `/Volumes/<共享名>`。
    ///
    /// 这不只是「位置一样」：这样挂出来的卷系统认得——访达侧边栏里就是那台 NAS 的共享，
    /// 桌面上就一个图标，卸载、推出、重启自动重连都走系统那套逻辑。
    /// 同一块共享已经挂着时，系统会把已有的卷直接交回来，不会再挂第二份。
    private static func viaSystemMount(_ drive: Drive, password: String?) -> OpResult? {
        guard let url = connectionURL(drive) else { return nil }
        // URL 来自用户输入或局域网广播名，必须按 AppleScript 字符串规则转义，
        // 否则一个引号就能把脚本结构破坏掉（`mount volume "x" & (do shell script "…")`）
        let safeURL = appleScriptQuote(url)

        // 凭据必须走 `as user name … with password …`，绝不能塞进 URL。
        // NetFS 的 mount volume 只收干净 URL：带 user:pass@ 的一律报 -1700
        //「不能将 … 转换为 "URL" 类型」——整盘 NAS 挂不上就是这么来的。
        var auth = ""
        if drive.proto != .nfs, !drive.username.isEmpty {
            auth = " as user name \"\(appleScriptQuote(drive.username))\""
            if let password, !password.isEmpty {
                auth += " with password \"\(appleScriptQuote(password))\""
            }
        }

        // 绝不能写成 `set v to mount volume …`：
        // macOS 26 起 mount volume 的返回值是个没法赋给变量的对象，赋值那一句直接抛
        // -2753「The variable v is not defined」——卷其实已经挂上了，脚本却报错，
        // 调用方就当成失败。所以不指望返回值，挂完自己扫一遍找挂载点。
        let script = """
        try
            mount volume "\(safeURL)"\(auth)
            return "OK"
        on error errMsg number errNum
            return "ERR:" & errNum & ":" & errMsg
        end try
        """
        // 脚本（含密码）从 stdin 给 osascript，不进 argv：
        // `ps` 看不到标准输入，而 ps 能看到命令行参数。
        let r = Shell.run("/usr/bin/osascript", ["-"], timeout: 20, input: script)
        let out = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if out == "OK" {
            if let v = waitForMount(drive: drive, timeout: 8) {
                return .ok("已挂载到 \(v.path)")
            }
            return .ok("已挂载")
        }
        if r.status != 0 {
            return .fail("系统挂载失败：\(friendly(out.isEmpty ? r.err : out))")
        }
        return .fail(friendly(out))
    }

    // MARK: 方式二：用 open 打开 smb:// 链接，交给系统弹窗处理

    private static func viaOpenURL(_ drive: Drive) -> OpResult? {
        // WebDAV 不能走 open：`open https://…` 会交给浏览器打开一个网页，不会挂载。
        // 它真正该走的是 viaSystemMount 里的 `mount volume "https://…"`。
        guard drive.proto != .webdav else { return nil }
        var comps = URLComponents()
        comps.scheme = drive.proto == .smb ? "smb" : "nfs"
        comps.host = encHost(drive.host)
        if let p = drive.port, p > 0 { comps.port = p }
        if !drive.share.isEmpty {
            comps.path = drive.share.hasPrefix("/") ? drive.share : "/" + drive.share
        }
        if !drive.username.isEmpty { comps.user = drive.username }
        if let v = drive.smbVersion.query { comps.queryItems = [URLQueryItem(name: "vers", value: v)] }
        guard let url = comps.url?.absoluteString else { return nil }

        let r = Shell.run("/usr/bin/open", [url], timeout: 10)
        guard r.ok else { return .fail("无法打开连接（\(redact(r.message))）") }
        if let v = waitForMount(drive: drive, timeout: 12) {
            return .ok("已挂载到 \(v.path)")
        }
        return .fail("已发起连接，但未检测到挂载结果（可能需要输入账号密码）")
    }

    // MARK: - 连接诊断

    struct Diagnosis {
        /// 试出来能用的版本；nil 表示全军覆没
        var workingVersion: SMBVersion?
        /// 每一步的人话记录，直接摊给用户看
        var log: [String] = []
    }

    /// 依次试用各个 SMB 协议版本，找出能连上的那个。
    ///
    /// 「协商失败」是 SMB 挂载最典型的坑：新版 Mac 想谈 3.1.1，老 NAS 只认 2.1，
    /// 一谈不拢就只说「无法连接」，用户根本看不出该改什么。
    /// 所以与其让用户去猜，不如把每个版本都试一遍。
    ///
    /// 注意：为了试下一个版本必须把当前挂载摘掉，属于「会断一下」的操作，
    /// 只在用户主动点「连接诊断」时跑。
    static func diagnoseSMB(_ drive: Drive,
                            progress: @escaping (String) -> Void,
                            completion: @escaping (Diagnosis) -> Void) {
        // 诊断会反复卸载/重挂，必须和其他挂载操作排同一条队列。
        MountOps.run {
            var result = Diagnosis()

            guard drive.proto == .smb else {
                result.log.append("只有 SMB 磁盘需要诊断协议版本，当前是 \(drive.proto.title)。")
                completion(result)
                return
            }

            // 已经挂着而且真的能读 → 当前设置就是好的，别折腾了
            if let v = MountScanner.match(drive: drive, in: MountScanner.scan()) {
                progress("检查当前连接…")
                if MountHealth.isHealthy(v.path) {
                    result.workingVersion = drive.smbVersion
                    result.log.append("当前连接正常，用的就是「\(drive.smbVersion.title)」，不用改。")
                    completion(result)
                    return
                }
                result.log.append("检测到挂载点「\(v.path)」已经失去响应，需要重连。")
            }

            let candidates: [SMBVersion] = [.auto, .v21, .v30, .v311]
            for version in candidates {
                progress("正在试用 \(version.title)…")
                // 先把当前挂载摘掉，否则 mount() 会直接返回「已经挂载」
                if let v = MountScanner.match(drive: drive, in: MountScanner.scan()) {
                    _ = unmount(v, force: true)
                    usleep(400_000)
                }
                switch mount(drive, versionOverride: version) {
                case .ok(let m):
                    result.workingVersion = version
                    result.log.append("✅ \(version.title)：连上了（\(m)）")
                    completion(result)
                    return
                case .fail(let m):
                    result.log.append("❌ \(version.title)：\(friendly(m))")
                }
            }
            result.log.append("四个版本都连不上，问题大概不在协议版本上——先看看 NAS 开没开机、账号密码对不对、共享名拼没拼错。")
            completion(result)
        }
    }

    // MARK: 辅助

    /// 把系统原始报错翻译成人话
    static func friendly(_ raw: String) -> String {
        // 系统报错会把整条连接串原样回显，里面可能带着密码——先抹掉再判断、再展示
        let safe = redact(raw)
        let m = safe.lowercased()
        if m.contains("file exists") {
            return "这个共享已经在系统里挂载过了，请先在 Finder 中断开，或直接用已有的那块"
        }
        if m.contains("user canceled") || raw.contains("-128") {
            return "系统登录窗口被关掉或超时了，请再试一次"
        }
        if m.contains("authentication") || m.contains("denied") || m.contains("logon") || m.contains("password") {
            return "账号或密码不正确"
        }
        if m.contains("timed out") || m.contains("timeout") || m.contains("connection failed") {
            return "连不上服务器（检查设备是否开机、SMB 服务是否开启、是否同一网络）"
        }
        if m.contains("no such file") || m.contains("not found") {
            return "服务器上没有这个共享文件夹"
        }
        if m.contains("permission") {
            return "没有权限访问这个共享"
        }
        return safe
    }

    /// 主机是否能解析（IP 或域名都支持，.local 走 Bonjour）
    ///
    /// 注意：`.local` 首次解析在这台机器上要 5～10 秒（多网卡、其中一个地址不通），
    /// 所以加了 2.5 秒上限——解析慢就先放行，交给真正的挂载动作判断，
    /// 免得用户在「预检」这一步干等。
    static func isReachableHost(_ host: String) -> Bool {
        guard !host.isEmpty else { return false }
        // 纯 NetBIOS 名字系统解析器不认，直接放行
        if !host.contains(".") && !host.contains(":") { return true }

        let sem = DispatchSemaphore(value: 0)
        var reachable = false
        DispatchQueue.global(qos: .utility).async {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(host, nil, &hints, &result)
            if let result { freeaddrinfo(result) }
            reachable = status == 0
            sem.signal()
        }
        if sem.wait(timeout: .now() + 2.5) == .timedOut {
            // .local / NetBIOS 首次解析本来就慢，放行交给真正的挂载动作判断；
            // 明确的 IP 或域名解析超时则视为不可达，别把错地址放过去白等 20 秒。
            return host.hasSuffix(".local")
        }
        return reachable
    }

    private static func waitForMount(drive: Drive, timeout: TimeInterval) -> MountedVolume? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let v = MountScanner.match(drive: drive, in: MountScanner.scan()) {
                return v
            }
            usleep(400_000)
        }
        return nil
    }

    /// 两个挂载点是不是同一处。标准化消除多余斜杠、`..` 一类写法，
    /// 忽略大小写是因为卷名的实际大小写常和用户输入不一致（APFS 默认不区分）。
    private static func samePath(_ a: String, _ b: String) -> Bool {
        let x = (a as NSString).standardizingPath
        let y = (b as NSString).standardizingPath
        return x.compare(y, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame
    }

    /// 挂载点当前是否真的是只读。`statfs` 直接读内核标志，比解析 `mount` 输出可靠。
    /// 返回 nil 表示查不到（此时不做判定，不能凭猜报错）。
    private static func isReadOnlyMount(_ path: String) -> Bool? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return (info.f_flags & UInt32(MNT_RDONLY)) != 0
    }

    /// 生成 smb://host/share 形式的连接串。
    ///
    /// **不带任何凭据**：账号密码由 AppleScript 的 `as user name … with password …`
    /// 单独传（见 viaSystemMount）。早期版本把 user:pass@ 拼进 URL，
    /// NetFS 一律拒收并报 -1700，等于 SMB 挂载从没真正走通。
    static func connectionURL(_ drive: Drive) -> String? {
        guard !drive.host.isEmpty else { return nil }
        // WebDAV 以前恒为 https://，导致说明书里推荐的 Alist 5005/5244 这类
        // 纯 HTTP 端口永远连不上。现在由每块盘的 webdavSecure 决定。
        var s = "\(drive.proto == .smb ? "smb" : (drive.proto == .nfs ? "nfs" : (drive.webdavSecure ? "https" : "http")))://"
        // host 也要编码：它可能来自局域网广播名 / 反查 DNS，不能假设干净。
        // 保留 IPv6 方括号和冒号，其余一律百分号编码，杜绝引号等字符破坏 URL 结构
        s += encHost(drive.host)
        if let p = drive.port, p > 0, p != drive.proto.defaultPort { s += ":\(p)" }
        if !drive.share.isEmpty {
            s += drive.share.hasPrefix("/") ? enc(drive.share) : "/" + enc(drive.share)
        }
        // 只读作为挂载选项交给系统挂载器：NetFS 会把 URL 的 query 透传给
        // mount_smbfs / mount_nfs / mount_webdav。挂载成功后还会再校验一次实际是不是只读。
        var query: [String] = []
        if drive.readOnly { query.append("rdonly") }
        if drive.proto == .smb, let v = drive.smbVersion.query { query.append("vers=\(v)") }
        if !query.isEmpty { s += "?" + query.joined(separator: "&") }
        return s
    }

    /// shell 单引号转义：把整段包进单引号，内部单引号用 '\'' 断开。
    /// 非 private：单测会直接验证含单引号的主机名不会被拼成可执行的 shell 片段。
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript 字符串字面量转义。
    ///
    /// 换行压成空格：脚本靠换行分隔语句，密码里混进一个换行就能插进任意语句。
    /// 宁可让这种密码挂载失败，也不能让它改写脚本。
    static func appleScriptQuote(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// 抹掉文本里的密码再往外给。
    ///
    /// 系统报错会把连接串原样回显，而这条字符串会进界面、通知和日志，
    /// 用户随手一截图密码就跟着出去了。
    static func redact(_ s: String) -> String {
        // 两种写法都要盖住：`smb://user:pass@host` 和 `//user:pass@host`
        // （mount_smbfs 认的是后者）。只认 `://` 的话，直连类的报错会把明文密码
        // 带进界面和诊断日志。分隔符用捕获组原样保留，替换后不会多出冒号。
        guard let re = try? NSRegularExpression(pattern: "(://|//)([^:/@\\s]+):([^@\\s]+)@") else { return s }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        var out = re.stringByReplacingMatches(in: s, range: range, withTemplate: "$1$2:***@")
        // osascript 语法错误会把整段脚本（含 with password "明文"）回显到 stderr，
        // 这种形式不是 URL，上面的正则盖不住，再单独擦一遍。
        if let pw = try? NSRegularExpression(pattern: "with password \"[^\"]*\"") {
            let r2 = NSRange(out.startIndex..<out.endIndex, in: out)
            out = pw.stringByReplacingMatches(in: out, range: r2,
                                              withTemplate: "with password \"***\"")
        }
        return out
    }

    /// 主机名编码：只放行域名 / IPv4 / 带方括号 IPv6 的合法字符
    private static func encHost(_ host: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: ".-_:[]%")
        return host.addingPercentEncoding(withAllowedCharacters: allowed) ?? host
    }

    private static func enc(_ s: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/:@?#[]")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
