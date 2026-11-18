import Foundation
import Network

/// 局域网里的网络磁盘设备
struct DiscoveredHost {
    var name: String          // Bonjour 实例名，例如 Z4S-I0C9
    var host: String          // 可用的连接地址，例如 Z4S-I0C9.local
    var proto: DiskProtocol
    var ip: String?           // 解析出的 IP（后台补，可能为 nil）
    var shares: [String] = [] // 该设备上的共享列表（按需拉取）
    /// 实际连接用地址：优先 IP（快），退回主机名（稳）
    var connectHost: String { ip ?? host }
    var address: String { "\(proto == .smb ? "smb" : "webdav")://\(connectHost)" }
}

/// 用 Bonjour 扫局域网里的 NAS / 文件服务器
enum LANDiscovery {

    private static let types: [(String, DiskProtocol)] = [
        ("_smb._tcp", .smb),
        ("_webdav._tcp", .webdav),
        ("_webdavs._tcp", .webdav)
    ]

    /// 扫描一段时间，把发现的设备回调出来。回调在后台线程。
    static func scan(duration: TimeInterval = 3.0,
                     onFound: @escaping ([DiscoveredHost]) -> Void,
                     onDone: @escaping ([DiscoveredHost]) -> Void) {
        let lock = NSLock()
        var results: [String: DiscoveredHost] = [:]   // key = "proto|name"
        var browsers: [NWBrowser] = []

        for (type, proto) in types {
            let params = NWParameters.tcp
            params.includePeerToPeer = false
            let browser = NWBrowser(for: .bonjour(type: type, domain: "local."), using: params)

            browser.browseResultsChangedHandler = { found, _ in
                var changed = false
                lock.lock()
                for r in found {
                    guard case let .service(name, _, _, _) = r.endpoint else { continue }
                    // 同名设备不同协议要分开记
                    let key = "\(proto.rawValue)|\(name)"
                    if results[key] == nil {
                        results[key] = DiscoveredHost(name: name, host: name + ".local", proto: proto)
                        changed = true
                    }
                }
                let snapshot = Array(results.values).sorted { $0.name < $1.name }
                lock.unlock()
                if AppEnvironment.value("LOG") == "1" {
                    FileHandle.standardError.write("[LAN] \(type) 结果 \(found.count) 条，累计 \(snapshot.count) 台\n".data(using: .utf8)!)
                }
                if changed { onFound(snapshot) }
            }
            browser.stateUpdateHandler = { st in
                if AppEnvironment.value("LOG") == "1" {
                    FileHandle.standardError.write("[LAN] browser \(type) → \(st)\n".data(using: .utf8)!)
                }
            }
            browser.start(queue: .global(qos: .userInitiated))
            browsers.append(browser)
        }

        // 收尾定时器：用 GCD 而不是 Timer。
        // Timer 只挂在 RunLoop 的 .default 模式上，而 App 处理 WebKit 消息、
        // 弹窗、拖拽时 RunLoop 会切到别的模式，定时器就一直不触发（踩过这个坑）。
        // GCD 定时与 RunLoop 模式无关，稳。
        let finished = NSLock()   // 兼作「只结束一次」的开关
        var done = false
        if AppEnvironment.value("LOG") == "1" {
            FileHandle.standardError.write("[LAN] 排定收尾定时 \(duration)s main=\(Thread.isMainThread)\n".data(using: .utf8)!)
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + duration) {
            finished.lock()
            if done { finished.unlock(); return }
            done = true
            finished.unlock()

            if AppEnvironment.value("LOG") == "1" {
                FileHandle.standardError.write("[LAN] 收尾定时触发，结束扫描\n".data(using: .utf8)!)
            }
            browsers.forEach { $0.cancel() }
            lock.lock()
            let final = Array(results.values).sorted { $0.name < $1.name }
            lock.unlock()
            onDone(final)
        }
    }

    /// 列出某台 SMB 服务器上的共享文件夹。
    ///
    /// 这里刻意用 **裸名字**（`//Z4S-I0C9`）而不是 `//Z4S-I0C9.local`：
    /// 裸名字走 NetBIOS 广播，实测 57ms 就返回；而 `.local` 走 mDNS，
    /// 这台机器上有两个网卡地址、其中一个不通，系统要等超时，实测 10 秒。
    ///
    /// 注意：这里**不接受明文密码**。`smbutil view //user:pass@host` 会把密码
    /// 写进子进程的 argv，同机任何进程 `ps` 一下就能看到——和 Keychain 里
    /// 「不走命令行、密码不进进程表」的设计直接冲突。带用户名时只写 `//user@host`，
    /// 密码交给系统钥匙串（访达里连过一次就有了）。
    static func listShares(host: String, username: String = "") -> [String] {
        let bare = bareName(host)
        var targets: [String] = []
        if !username.isEmpty { targets.append("//\(username)@\(bare)") }
        targets.append("//\(bare)")                      // 匿名
        if bare != host { targets.append("//\(host)") }   // 兜底：完整主机名

        for target in targets {
            var args = ["view"]
            if !target.contains(":") { args.append("-N") }  // 不带密码时禁止交互提示
            args.append(target)
            let r = Shell.run("/usr/bin/smbutil", args, timeout: 12)
            let shares = parseShares(r.out)
            if !shares.isEmpty { return shares }
        }
        return []
    }

    /// Z4S-I0C9.local → Z4S-I0C9
    static func bareName(_ host: String) -> String {
        var h = host
        if h.lowercased().hasSuffix(".local") { h = String(h.dropLast(6)) }
        return h
    }

    // MARK: - 网段扫描（Bonjour 不可用时的兜底）

    /// 本机所在的 IPv4 /24 网段前缀，例如 ["192.168.31"]
    static func localSubnets() -> [String] {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, addrs != nil else { return [] }
        defer { freeifaddrs(addrs) }

        var out: Set<String> = []
        var p = addrs
        while let cur = p {
            let ifa = cur.pointee
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: ifa.ifa_name)
                if !name.hasPrefix("lo") {
                    var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                                   &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: buf)
                        // 跳过 169.254（自分配地址）和 127.
                        if !ip.hasPrefix("169.254") && !ip.hasPrefix("127.") {
                            let parts = ip.split(separator: ".")
                            if parts.count == 4 { out.insert("\(parts[0]).\(parts[1]).\(parts[2])") }
                        }
                    }
                }
            }
            p = ifa.ifa_next
        }
        return Array(out)
    }

    /// 非阻塞 connect 探测某个 TCP 端口是否开着
    static func probeTCP(_ ip: String, port: UInt16, timeout: TimeInterval) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)   // Darwin 必须填，否则 connect 报 EINVAL
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return false }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var a = addr
        let r = withUnsafePointer(to: &a) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if r == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return false }

        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0
    }

    /// 扫本网段里开着 SMB 端口（445）的机器，返回 IP 列表。
    ///
    /// 为什么需要这个：Bonjour 浏览要「本地网络」隐私权限，用户一旦在系统弹窗里
    /// 点了「不允许」，NWBrowser 会一直停在 ready 却永远收不到结果，
    /// 而普通 TCP 连接不受影响（实测 smbutil 照常能用）。所以扫端口能兜住。
    static func scanSubnet(port: UInt16 = 445,
                           timeout: TimeInterval = 0.45,
                           concurrency: Int = 48) -> [String] {
        var hits: [String] = []
        let lock = NSLock()

        // 先看 ARP 缓存：最近通过话的机器几乎都在里面，能省掉整轮扫描
        var seeds: [String] = []
        for prefix in localSubnets() {
            seeds += arpHosts(prefix: prefix)
        }
        for ip in seeds where probeTCP(ip, port: port, timeout: 0.3) {
            lock.lock(); hits.append(ip); lock.unlock()
        }
        if !hits.isEmpty { return hits }

        for prefix in localSubnets() {
            let sem = DispatchSemaphore(value: concurrency)
            let group = DispatchGroup()
            for i in 1...254 {
                let ip = "\(prefix).\(i)"
                sem.wait()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    defer { sem.signal(); group.leave() }
                    if probeTCP(ip, port: port, timeout: timeout) {
                        lock.lock(); hits.append(ip); lock.unlock()
                    }
                }
            }
            group.wait()
        }
        return hits.sorted()
    }

    /// 从 `arp -an` 里挑出本网段的 IP
    private static func arpHosts(prefix: String) -> [String] {
        let r = Shell.run("/usr/sbin/arp", ["-an"], timeout: 4)
        var out: [String] = []
        for line in r.out.components(separatedBy: "\n") {
            // ? (192.168.31.17) at 0:11:32:... on en0 ifscope [ethernet]
            guard let l = line.range(of: "("),
                  let rr = line.range(of: ")") else { continue }
            let ip = String(line[l.upperBound..<rr.lowerBound])
            if ip.hasPrefix(prefix + ".") { out.append(ip) }
        }
        return out
    }

    /// IP → 主机名（反查 mDNS / DNS），拿不到就返回 nil
    static func reverseName(_ ip: String) -> String? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return nil }
        var a = addr
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let r = withUnsafePointer(to: &a) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size),
                            &buf, socklen_t(buf.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard r == 0 else { return nil }
        let name = String(cString: buf)
        return name.isEmpty ? nil : bareName(name)
    }

    /// 把主机名解析成 IP。慢（首次 5 秒左右），只在后台调。
    static func resolveIP(_ host: String) -> String? {
        resolveIPs(host).first
    }

    /// 解析出**全部** IPv4。
    /// 有的 NAS 双网卡会在 mDNS 里注册两个地址，其中一个可能是死的，
    /// 只拿第一个会有 50% 概率撞到不通的那个，所以挂载时要把它们都试一遍。
    static func resolveIPs(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let result else { return [] }
        defer { freeaddrinfo(result) }

        var ips: [String] = []
        var p: UnsafeMutablePointer<addrinfo>? = result
        while let cur = p {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(cur.pointee.ai_addr, cur.pointee.ai_addrlen,
                           &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: buf)
                if !ip.isEmpty && !ips.contains(ip) { ips.append(ip) }
            }
            p = cur.pointee.ai_next
        }
        return ips
    }

    /// 从解析出的地址里挑一个指定端口真能连上的
    static func bestIP(_ host: String, port: UInt16? = nil, timeout: TimeInterval = 0.6) -> String? {
        let ips = resolveIPs(host)
        if ips.count <= 1 { return ips.first }
        let p = port ?? 445
        for ip in ips where probeTCP(ip, port: p, timeout: timeout) { return ip }
        return ips.first
    }

    /// 解析 smbutil view 的输出：
    /// Share                     Type    Comments
    /// ----------                ----    --------
    /// 极空间HD                   Disk
    /// IPC$                      Pipe    IPC Service
    private static func parseShares(_ text: String) -> [String] {
        var shares: [String] = []
        var seenHeader = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("Share") && line.contains("Type") { seenHeader = true; continue }
            if line.allSatisfy({ $0 == "-" || $0 == " " }) { continue }
            guard seenHeader else { continue }
            if line.contains("listed") { break }

            // 用「Disk / Pipe / Printer」把这一行切开
            guard let r = line.range(of: "  Disk", options: .backwards)
                    ?? line.range(of: "  Pipe", options: .backwards)
                    ?? line.range(of: "  Printer", options: .backwards) else { continue }
            let name = String(line[line.startIndex..<r.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let kind = String(line[r.lowerBound...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            // 只看磁盘共享，跳过 IPC$ 这类管道
            if kind.hasPrefix("Disk") { shares.append(name) }
        }
        return shares
    }
}
