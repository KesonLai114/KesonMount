import Foundation

/// 解析系统挂载表，找出所有网络磁盘
enum MountScanner {

    static func scan() -> [MountedVolume] {
        let result = Shell.run("/sbin/mount", [], timeout: 8)
        guard result.ok else { return [] }
        return parse(result.out)
    }

    static func parse(_ text: String) -> [MountedVolume] {
        var volumes: [MountedVolume] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            guard let onRange = line.range(of: " on ", options: .backwards) else { continue }
            let sourceRaw = String(line[line.startIndex..<onRange.lowerBound])
            let rest = String(line[onRange.upperBound...])

            guard let parenStart = rest.range(of: " (", options: .backwards) else { continue }
            let path = String(rest[rest.startIndex..<parenStart.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            var opts = String(rest[parenStart.upperBound...])
            if opts.hasSuffix(")") { opts = String(opts.dropLast()) }

            let parts = opts.components(separatedBy: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            let fsType = parts.first?.lowercased() ?? ""

            var owner = ""
            for p in parts where p.hasPrefix("mounted by ") {
                owner = String(p.dropFirst("mounted by ".count))
            }

            // 老版本用户态挂载可能把 //user:pass@host 留在 mount 表里；
            // 先抹掉密码，再交给界面 / 配置持久化，绝不让它明文落盘。
            let decodedSource = MountService.redact(sourceRaw.removingPercentEncoding ?? sourceRaw)
            let volume = MountedVolume(source: decodedSource, path: path, fsType: fsType, owner: owner)
            if volume.isNetwork {
                volumes.append(volume)
            }
        }
        return volumes
    }

    // MARK: - 服务器身份

    /// 把同一台 NAS 的各种写法收敛成同一个键：
    ///   `Z4S-I0C9._smb._tcp.local` / `Z4S-I0C9.local` / `Z4S-I0C9` → `z4s-i0c9`
    ///   `192.168.31.4` → `192.168.31.4`
    ///
    /// 为什么要归一化：系统（访达）挂载时用的是 Bonjour 服务名
    /// `Z4S-I0C9._smb._tcp.local`，网盘管家自己挂载时用的是 IP 或 `Z4S-I0C9.local`。
    /// 字面上完全不同，其实是同一台机器上的同一个共享——不归一化，程序就会以为
    /// 「没挂上」，于是再挂一份，桌面上多出一个硬盘图标。
    static func serverKey(_ raw: String) -> String {
        var h = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        if let at = h.firstIndex(of: "@") { h = String(h[h.index(after: at)...]) }
        if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
        for suffix in ["._smb._tcp.local", "._afpovertcp._tcp.local", "._smb._tcp", "._afpovertcp._tcp"]
        where h.hasSuffix(suffix) {
            h = String(h.dropLast(suffix.count)) + ".local"
            break
        }
        while h.hasSuffix(".") { h = String(h.dropLast()) }
        if h.hasSuffix(".local") { h = String(h.dropLast(".local".count)) }
        return h
    }

    /// 是不是 IPv4 地址（用来判断「一边 IP 一边主机名」）
    static func isIPAddress(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber) && Int(part).map { $0 <= 255 } == true
        }
    }

    /// 这块盘在系统挂载表里可能出现的所有服务器键（主机名 + 上次记下的 IP）
    static func hostAliases(for drive: Drive) -> Set<String> {
        var set: Set<String> = []
        for h in [drive.host, drive.ipHint ?? ""] where !h.isEmpty {
            let key = serverKey(h)
            if !key.isEmpty { set.insert(key) }
        }
        return set
    }

    /// 找出某个磁盘对应的挂载卷
    static func match(drive: Drive, in volumes: [MountedVolume]) -> MountedVolume? {
        // 1. 用户指定了挂载点，且正好有卷挂在那儿——就是它
        if !drive.mountPoint.isEmpty,
           let exact = volumes.first(where: { $0.path == drive.mountPoint }) {
            return exact
        }

        let aliases = hostAliases(for: drive)
        let share = drive.share.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // 2. 共享名 + 服务器都对得上（IP、主机名、带 Bonjour 服务后缀的写法都算同一台）
        var strong: [MountedVolume] = []
        if !share.isEmpty {
            strong = volumes.filter {
                $0.shareName.lowercased() == share && aliases.contains(serverKey($0.host))
            }
        } else if !aliases.isEmpty {
            // 没填共享名（NFS 导出路径这类），只能靠服务器对
            strong = volumes.filter { aliases.contains(serverKey($0.host)) }
        }
        if let best = preferred(strong) { return best }

        // 3. 服务器写法对不上（比如盘里只填了 IP，系统那边挂的是主机名），但共享名对得上。
        //
        //    限定：这些同名卷必须来自同一台服务器。两台 NAS 都有「Public」时裸按共享名
        //    认，会把别人的盘当成自己的——界面显示「已挂载」，用户读写却落在另一台机器上。
        //    宁可回「未挂载」然后去尝试挂载（真重复了系统会报 exists），也不要认错。
        if !share.isEmpty {
            let byShare = volumes.filter { $0.shareName.lowercased() == share }
            let servers = Set(byShare.map { serverKey($0.host) })
            if servers.count == 1, let best = preferred(byShare) { return best }
        }

        return nil
    }

    /// 同一块共享被挂了多份时，挑最「正牌」的那个：
    /// `/Volumes/<共享名>`（系统标准位置，也是访达挂的位置）> 其他位置 > `~/Volumes/...`
    /// 长度短的优先，`极空间HD` 胜过 `极空间HD-1`。
    static func preferred(_ volumes: [MountedVolume]) -> MountedVolume? {
        volumes.min { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            return a.path.count < b.path.count
        }
    }

    private static func rank(_ v: MountedVolume) -> Int {
        if v.path.hasPrefix("/Volumes/") { return 0 }
        if v.path.contains("/Volumes/") { return 2 }   // ~/Volumes/... 老版本网盘管家挂的
        return 1
    }

    /// 找出「同一块共享被挂了不止一次」里明确多余的那些挂载点。
    ///
    /// 只认两类，其余一律不碰（宁可留着，也不误摘用户自己的盘）：
    ///   1. 老版本网盘管家挂到 `~/Volumes/...` 的那份——正牌的在 `/Volumes` 已经有一份；
    ///   2. 系统在同一个共享上又挂出来的 `xxx-1`。
    static func redundant(in volumes: [MountedVolume]) -> [MountedVolume] {
        var groups: [String: [MountedVolume]] = [:]
        for v in volumes {
            groups[v.shareName.lowercased(), default: []].append(v)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var out: [MountedVolume] = []
        for list in groups.values where list.count > 1 {
            guard let keeper = preferred(list) else { continue }
            for v in list where v.path != keeper.path {
                if v.path.hasPrefix(home + "/Volumes/") {
                    out.append(v)
                    continue
                }
                if v.path.hasPrefix(keeper.path + "-"),
                   v.path.dropFirst(keeper.path.count + 1).allSatisfy(\.isNumber),
                   likelySameServer(keeper, v) {
                    out.append(v)
                }
            }
        }
        return out
    }

    /// 两个挂载点是不是同一台服务器。
    /// IP 和主机名在字面上永远对不上，但它们指向同一台机器的可能性远大于
    /// 「两台不同的 NAS 恰好共享同名」，所以只有「一边 IP 一边名字」时按同一台算。
    private static func likelySameServer(_ a: MountedVolume, _ b: MountedVolume) -> Bool {
        let ka = serverKey(a.host), kb = serverKey(b.host)
        if ka == kb { return true }
        return isIPAddress(ka) != isIPAddress(kb)
    }

    /// 把当前已挂载但还没纳入管理的网络磁盘，转成 Drive
    static func adoptableVolumes(volumes: [MountedVolume], known: [Drive]) -> [Drive] {
        var result: [Drive] = []
        for v in volumes {
            let alreadyKnown = known.contains { d in
                match(drive: d, in: [v]) != nil
            }
            guard !alreadyKnown else { continue }

            var d = Drive()
            d.name = v.shareName
            d.proto = proto(for: v)
            d.host = Drive.normalizeHost(v.host)
            d.username = MountService.redact(v.userName)
            // 记住它现在挂在哪。用户在其他软件里配的文件路径都指着这个位置，
            // 重启后必须原样挂回同一个地方——路径变了，那些路径就全读不到文件。
            d.mountPoint = v.path
            d.imported = true
            // 导入的默认开机自动挂载：用户挂过一次就是想让它在，别再让他点第二遍
            d.autoMount = true
            d.note = "从系统已挂载磁盘导入"
            // 没有共享名的「服务器根」卷纳管了也没用：macOS 的 NetFS 必须知道共享名
            // 才挂得出来（实测 smb://host/ 只会弹个永远等不到结果的窗口），重挂必然
            // 失败。跳过，不要凭空造一块永远挂不上的盘。
            guard !v.sourceShare.isEmpty else { continue }
            d.share = v.shareName
            result.append(d)
        }
        return result
    }

    static func proto(for volume: MountedVolume) -> DiskProtocol {
        switch volume.fsType {
        case "webdav": return .webdav
        case "nfs": return .nfs
        default: return .smb
        }
    }
}
