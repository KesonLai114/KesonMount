import Foundation

// MARK: - 协议类型

enum DiskProtocol: String, Codable, CaseIterable, Identifiable {
    case smb
    case webdav
    case nfs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smb: return "SMB"
        case .webdav: return "WebDAV"
        case .nfs: return "NFS"
        }
    }

    var symbol: String {
        switch self {
        case .smb: return "externaldrive.connected.to.line.below"
        case .webdav: return "cloud"
        case .nfs: return "server.rack"
        }
    }

    var defaultPort: Int {
        switch self {
        case .smb: return 445
        case .webdav: return 443
        case .nfs: return 2049
        }
    }

    var hostPlaceholder: String {
        switch self {
        case .smb: return "例如 192.168.1.10 或 NAS 的主机名"
        case .webdav: return "例如 nas.example.com 或 192.168.1.10:5006"
        case .nfs: return "例如 192.168.1.10"
        }
    }

    var sharePlaceholder: String {
        switch self {
        case .smb: return "共享文件夹名称，例如 极空间HD"
        case .webdav: return "服务器上的路径，例如 /dav 或 /webdav"
        case .nfs: return "导出路径，例如 /volume1/video"
        }
    }

    var summary: String {
        switch self {
        case .smb: return "极空间、群晖、威联通、Windows 共享、Mac 共享"
        case .webdav: return "坚果云、Nextcloud、Alist、各类支持 WebDAV 的网盘"
        case .nfs: return "Linux / NAS 的 NFS 导出目录（需要管理员权限）"
        }
    }
}

// MARK: - SMB 协议版本

/// macOS 的 SMB 客户端会先和服务器「协商」用哪个版本的协议。
/// 老 NAS / 老路由器 / 部分电视盒子共享只肯用 2.1，而新版系统默认想谈 3.1.1，
/// 一谈不拢就报「无法连接」——这是 SMB 挂载失败最常见的原因，
/// 所以这里让用户能手动钉死版本。
///
/// 实现上只能拼进 smb:// URL 的查询参数：
///   - `mount_smbfs -o vers=2.1` 实测报 "option not supported"，用不了
///   - `//host/share?vers=2.1` 与 `smb://host/share?vers=2.1` 都能被正常解析
enum SMBVersion: String, Codable, CaseIterable, Identifiable {
    case auto = "auto"
    case v21 = "2.1"
    case v30 = "3.0"
    case v311 = "3.1.1"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "自动协商"
        case .v21: return "SMB 2.1"
        case .v30: return "SMB 3.0"
        case .v311: return "SMB 3.1.1"
        }
    }

    var detail: String {
        switch self {
        case .auto:
            return "默认。由 Mac 和 NAS 自动协商，绝大多数情况都能连上"
        case .v21:
            return "兼容性最好。老 NAS、老路由器、智能电视的共享目录通常只认这个"
        case .v30:
            return "支持传输加密与多通道，速度和安全性都比 2.1 好"
        case .v311:
            return "最新版，需要 NAS 和 Mac 都支持；协商失败时报「无法连接」就退回 2.1 试试"
        }
    }

    /// 拼进 URL 的查询值；自动协商时返回 nil（不加参数）
    var query: String? {
        self == .auto ? nil : rawValue
    }

    static func from(raw: String?) -> SMBVersion {
        guard let raw else { return .auto }
        return SMBVersion(rawValue: raw) ?? .auto
    }
}

// MARK: - 网络磁盘

struct Drive: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var proto: DiskProtocol = .smb
    var host: String = ""
    var share: String = ""
    var username: String = ""
    /// WebDAV 是否走 HTTPS。关掉后用 http://，供 Alist 之类局域网 HTTP WebDAV 使用。
    /// 老配置没有这个键，默认 true（HTTPS），行为与旧版一致。
    var webdavSecure: Bool = true
    var port: Int? = nil
    var mountPoint: String = ""
    var autoMount: Bool = false
    var readOnly: Bool = false
    /// 掉线后自动重挂。默认开：SMB 隔一段时间就掉是常态，用户不该每次手动点
    var autoRemount: Bool = true
    /// SMB 协议版本（仅 proto == .smb 时有意义）
    var smbVersion: SMBVersion = .auto
    var note: String = ""
    var imported: Bool = false
    /// 上次解析到的 IP。挂载时优先用它——比主机名快一个数量级
    var ipHint: String? = nil
    /// NAS 网卡的 MAC 地址。填了之后，设备睡眠导致连不上时会用
    /// Wake-on-LAN 先把它唤醒再挂载（局域网发现时可以自动带出来）
    var macAddress: String? = nil
    /// 只在这些 Wi-Fi 下才自动挂载。空数组 = 不限制，去哪都挂
    var allowedSSIDs: [String] = []
    var createdAt: Date = Date()

    /// 展示用地址，例如 smb://192.168.1.10/极空间HD
    var address: String {
        var s = "\(proto == .webdav ? (webdavSecure ? "https" : "http") : proto.rawValue)://"
        s += host
        if let p = port, p > 0, p != proto.defaultPort { s += ":\(p)" }
        if !share.isEmpty {
            s += share.hasPrefix("/") ? share : "/" + share
        }
        return s
    }

    /// 挂载点：默认和系统（访达）完全一致——`/Volumes/<共享名>`。
    ///
    /// 以前默认挂到 `~/Volumes/<名称>`，看着更「干净」，实际有两个坑：
    ///   1. 同一块共享会被挂两遍——网盘管家一份在 `~/Volumes`，访达一份在 `/Volumes`，
    ///      桌面上直接多出一倍的硬盘图标；
    ///   2. 两边路径不一样，用户在别的软件里配好的路径，换个挂载方式就失效。
    /// 现在统一走系统标准位置：不管谁挂的，都是同一个卷、同一个路径。
    var resolvedMountPoint: String {
        if !mountPoint.isEmpty { return mountPoint }
        return Drive.standardMountPoint(share: share, name: name)
    }

    /// 系统标准挂载点：`/Volumes/<共享名>`
    static func standardMountPoint(share: String, name: String) -> String {
        let sharePath = share.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        // 共享名可能是 WebDAV / NFS 的路径（/dav、/volume1/video），取最后一段当卷名
        let base = sharePath.isEmpty ? name : (sharePath as NSString).lastPathComponent
        return "/Volumes/" + sanitize(base)
    }

    /// 规范化主机名：去掉 smb:// 前缀、Bonjour 服务后缀（Z4S._smb._tcp.local → Z4S.local）
    ///
    /// 同时清掉引号、反斜杠和控制字符。host 有三个来源都不完全可信：
    /// 用户手输、局域网 Bonjour 广播名、系统挂载表。这些字符会破坏后面拼的
    /// URL 和 AppleScript 字符串结构，进配置之前必须清掉（真正用的时候还会
    /// 再做一次百分号编码，双保险）。
    static func normalizeHost(_ raw: String) -> String {
        var h = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        while h.hasSuffix("/") { h = String(h.dropLast()) }
        let suffixes = ["._smb._tcp.local", "._afpovertcp._tcp.local", "._smb._tcp", "._afpovertcp._tcp"]
        for suffix in suffixes where h.lowercased().hasSuffix(suffix) {
            h = String(h.dropLast(suffix.count)) + ".local"
            break
        }
        // 清掉破坏性字符：引号 / 反斜杠 / 控制字符
        let hostile = CharacterSet(charactersIn: "\"'\\`")
            .union(.controlCharacters)
        h = h.components(separatedBy: hostile).joined()
        return h
    }

    /// 把 "nas.local:5006" 拆成主机与端口。
    ///
    /// IPv6 要特别小心：裸地址 `2001:db8::1` 有多个冒号，不能按最后一个冒号拆
    /// （会拆出 host `2001:db8:` + 端口 1 这种四不像）；带方括号的
    /// `[2001:db8::1]:445` 则要认出方括号后再取端口。
    static func splitHostPort(_ raw: String) -> (host: String, port: Int?) {
        var h = normalizeHost(raw)
        var port: Int? = nil

        // [IPv6]:port / [IPv6]
        if h.hasPrefix("["), let close = h.firstIndex(of: "]") {
            let inner = String(h[h.index(after: h.startIndex)..<close])
            let rest = String(h[h.index(after: close)...])
            if rest.hasPrefix(":"), let p = Int(rest.dropFirst()), p > 0, p < 65536 {
                port = p
            }
            return (inner.isEmpty ? h : inner, port)
        }

        let colonCount = h.reduce(0) { $0 + ($1 == ":" ? 1 : 0) }
        // 裸 IPv6：两个以上冒号，整串都是地址，没有端口
        if colonCount >= 2 { return (h, nil) }

        // IPv4:port / 主机名:port（只有一个冒号时才有端口）
        if colonCount == 1, let colon = h.lastIndex(of: ":") {
            let tail = String(h[h.index(after: colon)...])
            if let p = Int(tail), p > 0, p < 65536 {
                port = p
                h = String(h[..<colon])
            }
        }
        return (h, port)
    }

    static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\")
        let cleaned = s.components(separatedBy: bad).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "网络磁盘" : trimmed
    }

    /// 挂载点是否安全。
    ///
    /// 网络盘会被「挂」在一个已存在的目录上，原目录内容随即被藏起来——
    /// 写进 `/Users/x/.ssh` 或 `~/Library` 的东西，最后全落到远程卷上。
    /// 黑名单永远列不全（家目录下的敏感目录无穷无尽），所以这里改成白名单：
    /// 只接受 `/Volumes/<名>`。
    ///
    /// `~/Volumes/<名>` 不再放行：它只有用户态挂载器（mount_smbfs）挂得进去，
    /// 而那条路必须把密码拼进命令行参数，同机 `ps` 可见。现在统一挂在
    /// `/Volumes/<共享名>`，和访达完全一致。
    static func isSafeMountPoint(_ raw: String) -> Bool {
        guard !raw.isEmpty else { return true }   // 留空 = 用系统标准位置 /Volumes/<共享名>
        let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.hasPrefix("/Volumes/") else { return false }
        let comps = p.components(separatedBy: "/").filter { !$0.isEmpty }
        // 必须至少两级：单独一个 /Volumes 是系统根挂载点，往上挂盘会盖掉所有卷
        guard comps.count >= 2 else { return false }
        guard !comps.contains(where: { $0 == ".." || $0 == "." }) else { return false }
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, proto, host, share, username, port, mountPoint
        case autoMount, readOnly, autoRemount, smbVersion, note, imported, createdAt, ipHint
        case macAddress, allowedSSIDs, webdavSecure
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        proto = (try? c.decode(DiskProtocol.self, forKey: .proto)) ?? .smb
        host = Drive.normalizeHost((try? c.decode(String.self, forKey: .host)) ?? "")
        share = (try? c.decode(String.self, forKey: .share)) ?? ""
        username = (try? c.decode(String.self, forKey: .username)) ?? ""
        // 端口必须落在 1...65535。导入的是外部 JSON，越界值会让后面的
        // `UInt16(...)` 直接 trap（整个 App 闪退，而不是报一个错）。
        if let decoded = try? c.decode(Int.self, forKey: .port), (1...65535).contains(decoded) {
            port = decoded
        } else {
            port = nil
        }
        mountPoint = (try? c.decode(String.self, forKey: .mountPoint)) ?? ""
        autoMount = (try? c.decode(Bool.self, forKey: .autoMount)) ?? false
        readOnly = (try? c.decode(Bool.self, forKey: .readOnly)) ?? false
        // 老配置没有这两个键，默认「自动重挂开 + 版本自动协商」正是想要的行为
        autoRemount = (try? c.decode(Bool.self, forKey: .autoRemount)) ?? true
        smbVersion = (try? c.decode(SMBVersion.self, forKey: .smbVersion)) ?? .auto
        note = (try? c.decode(String.self, forKey: .note)) ?? ""
        imported = (try? c.decode(Bool.self, forKey: .imported)) ?? false
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        ipHint = try? c.decode(String.self, forKey: .ipHint)
        // 老配置没有这两个键：没有 MAC 就没有网络唤醒，没有白名单就是「不限制」，
        // 都正好是老行为，升级不需要用户做任何事
        let mac = (try? c.decode(String.self, forKey: .macAddress)).map { Drive.normalizeMAC($0) }
        macAddress = (mac?.isEmpty == false) ? mac : nil
        allowedSSIDs = (try? c.decode([String].self, forKey: .allowedSSIDs)) ?? []
        // 缺省 = HTTPS：老备份文件里没有这个键，升级后不会突然变成明文 HTTP
        webdavSecure = (try? c.decode(Bool.self, forKey: .webdavSecure)) ?? true
    }

    /// 规范化 MAC 地址，统一成大写冒号分隔的 AA:BB:CC:DD:EE:FF。
    ///
    /// 用户可能从路由器后台抄成 aabbccddeeff，也可能写成 AA-BB-CC-DD-EE-FF，
    /// 统一成一种格式，后面发魔术包时才不会出错。位数不对就返回空串。
    static func normalizeMAC(_ raw: String) -> String {
        let hex = raw.uppercased().filter { $0.isHexDigit }
        guard hex.count == 12 else { return "" }
        var out: [String] = []
        var index = hex.startIndex
        for _ in 0..<6 {
            let end = hex.index(index, offsetBy: 2)
            out.append(String(hex[index..<end]))
            index = end
        }
        return out.joined(separator: ":")
    }
}

// MARK: - 系统当前挂载的卷

struct MountedVolume: Identifiable, Hashable {
    let source: String        // 原始来源，已做百分号解码
    let path: String          // 挂载点
    let fsType: String        // smbfs / webdav / nfs ...
    let owner: String

    var id: String { path }

    var isNetwork: Bool {
        ["smbfs", "afpfs", "webdav", "nfs", "cddafs"].contains(fsType)
    }

    /// 文件系统展示名：smbfs → SMB
    var fsTitle: String {
        switch fsType {
        case "smbfs": return "SMB"
        case "webdav": return "WebDAV"
        case "nfs": return "NFS"
        case "afpfs": return "AFP"
        default: return fsType.uppercased()
        }
    }

    /// 从来源里解析出服务器地址（去掉用户名）
    var host: String {
        var s = source
        if s.hasPrefix("//") { s = String(s.dropFirst(2)) }
        if let at = s.firstIndex(of: "@") {
            s = String(s[s.index(after: at)...])
        }
        if let slash = s.firstIndex(of: "/") {
            s = String(s[..<slash])
        }
        return s
    }

    var userName: String {
        var s = source
        if s.hasPrefix("//") { s = String(s.dropFirst(2)) }
        guard let at = s.firstIndex(of: "@") else { return "" }
        let credential = String(s[..<at])
        // 历史遗留的用户态挂载可能留下 //user:pass@host：只取冒号前的用户名，
        // 绝不能让密码流进界面、drives.json 或配置备份。
        return credential.split(separator: ":", maxSplits: 1,
                                omittingEmptySubsequences: false).first.map(String.init) ?? ""
    }

    var shareName: String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? source : name
    }

    /// 从挂载来源里解析出共享名；形如 `smb://host/`（没有共享名）时为空串。
    /// 用来区分「挂了某个共享」和老版本误纳管的服务器根卷——两者卷路径不同，
    /// 不能被当成同一块盘，否则会被误判成「一个名为 Z4S-I0C9 的共享」。
    /// 当前版本已不再支持服务器根挂载（NetFS 必须知道共享名才挂得出卷），
    /// DriveStore 启动时会清掉这类老配置。
    var sourceShare: String {
        var s = source
        if s.hasPrefix("//") { s = String(s.dropFirst(2)) }
        // 先去掉 user[:pass]@，剩下的就是 host[:port]/share
        if let at = s.firstIndex(of: "@") {
            s = String(s[s.index(after: at)...])
        }
        // 只剥一层「服务器」：剥完剩下的整段都是共享名 / 导出路径。
        // 早先这里在无用户名时先把主机剥掉、末尾又无条件剥一次，导致
        // `//host/share` 这种匿名挂载被解析成空串，扫描出来的卷会被当成
        // 「整台服务器根」跳过，纳不进来。
        guard let slash = s.firstIndex(of: "/") else { return "" }
        return String(s[s.index(after: slash)...])
    }

    /// 容量信息
    var capacity: (total: Int64, free: Int64)? {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let total = attrs[.systemSize] as? NSNumber,
              let free = attrs[.systemFreeSize] as? NSNumber,
              total.int64Value > 0 else { return nil }
        return (total.int64Value, free.int64Value)
    }
}

// MARK: - 格式化工具

enum Fmt {
    static func bytes(_ value: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useTB, .useGB, .useMB]
        return f.string(fromByteCount: value)
    }

    static func percent(used: Int64, total: Int64) -> Int {
        guard total > 0 else { return 0 }
        return Int((Double(used) / Double(total) * 100).rounded())
    }
}
