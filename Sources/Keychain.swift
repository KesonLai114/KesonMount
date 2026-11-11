import Foundation
import Security

/// 用系统钥匙串保存密码，避免明文落盘。
///
/// 全部走 Security framework 的进程内 API（SecItemAdd / SecItemCopyMatching /
/// SecItemDelete），**不经过 `security` 命令行**：命令行方案的 `-w <密码>`
/// 会把密码写进子进程参数，同机器其他用户用 `ps` 就能看到，而写钥匙串时
/// 密码最长要在参数里待好几秒。进程内 API 的密码只以 Data 形式出现在
/// 自己的内存里，不进进程表。
///
/// 兼容性已实测：framework 能读旧版本用 `security -T` 写入的条目，
/// 反过来 CLI 也能读 framework 写入的条目，ad-hoc 重新签名后照样读得到。
enum Keychain {

    /// 统一密码库的服务名
    private static let vaultService = "NetMount"
    private static let vaultAccount = "vault"

    /// 进程内缓存。钥匙串读一次就够了，反复读只会反复触发授权。
    private static var vault: [String: String]?

    /// 保护 vault 的锁。读写并不是一条线程：主线程的界面快照会读，
    /// 后台挂载线程会写（含从系统钥匙串继承密码），两边都是「读快照→改→写回」，
    /// 不串行化就会互相覆盖，丢掉刚存进去的密码——下次挂载只能看到「认证失败」。
    /// 用递归锁：save / password 内部会先 loadVault 再 writeVault，两层加锁不能死锁。
    private static let lock = NSRecursiveLock()

    /// 所有盘的密码存在**同一个**条目里，而不是一盘一条。
    ///
    /// 原因：ad-hoc 签名的 App 每重新编译一次，二进制的 cdhash 就变了，钥匙串里
    /// 按条目记录的授权随之失效——重新编译后第一次读密码就会弹框要授权。
    /// 条目越多弹得越多：两块盘就弹两次，十块盘弹十次。合成一条只弹一次。
    private static func loadVault() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let vault { return vault }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: vaultService,
            kSecAttrAccount as String: vaultAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        var dict: [String: String] = [:]
        if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
           let data = out as? Data,
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            dict = decoded
        }
        vault = dict
        return dict
    }

    @discardableResult
    private static func writeVault(_ dict: [String: String]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(dict) else { return false }
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: vaultService,
            kSecAttrAccount as String: vaultAccount
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(match as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(match.merging(attrs) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { return false }
        vault = dict
        return true
    }

    // MARK: - 网盘管家自己存的密码（generic password）

    /// 把密码存进钥匙串。返回是否真的写成功了。
    ///
    /// 用「先改、改不到才新增」而不是「先删后加」：钥匙串被锁、用户拒绝授权、
    /// 磁盘满的时候，后者的旧密码已经删了、新密码又没写进去，而调用方
    /// 还以为保存成功——之后挂载就是莫名其妙的认证失败，且无从排查。
    @discardableResult
    static func save(password: String, for drive: Drive) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var dict = loadVault()
        dict[drive.id.uuidString] = password
        guard writeVault(dict) else { return false }
        deleteLegacy(for: drive)
        return true
    }

    static func password(for drive: Drive) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let pw = loadVault()[drive.id.uuidString], !pw.isEmpty { return pw }
        // 兼容老版本「一盘一条」的旧条目。读到之后顺手搬进统一库，
        // 删掉旧条目——之后再重新编译，就不必为这一块盘单独授权了。
        guard let legacy = legacyPassword(for: drive) else { return nil }
        var dict = loadVault()
        dict[drive.id.uuidString] = legacy
        if writeVault(dict) { deleteLegacy(for: drive) }
        return legacy
    }

    static func hasPassword(for drive: Drive) -> Bool {
        password(for: drive) != nil
    }

    static func delete(for drive: Drive) {
        lock.lock()
        defer { lock.unlock() }
        // 必须无条件读一次库再删：vault 只在本进程读过钥匙串后才在内存里，
        // 冷启动后直接删盘时它是 nil——旧逻辑会静默跳过，统一库里的明文密码
        // 永久残留，导入同 id 的配置还能把它复活。宁可多弹一次授权。
        var dict = loadVault()
        if dict.removeValue(forKey: drive.id.uuidString) != nil {
            _ = writeVault(dict)
        }
        deleteLegacy(for: drive)
    }

    // MARK: - 老版本遗留的条目（一盘一条，只读兼迁移，写不再使用）

    private static func legacyService(for drive: Drive) -> String {
        "NetMount:\(drive.id.uuidString)"
    }

    private static func legacyPassword(for drive: Drive) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService(for: drive),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let pw = String(data: data, encoding: .utf8) else { return nil }
        return pw.isEmpty ? nil : pw
    }

    private static func deleteLegacy(for drive: Drive) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService(for: drive)
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - 系统里已有的凭据（访达 / 系统共享连过就会留下）

    /// 系统钥匙串里是否存过这台服务器的密码。只查元数据，不会弹授权框。
    static func hasSystemCredential(host: String) -> Bool {
        guard !host.isEmpty else { return false }
        for candidate in hostCandidates(host) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassInternetPassword,
                kSecAttrServer as String: candidate,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess { return true }
        }
        return false
    }

    /// 取出系统保存的密码。
    /// 注意：这一步系统可能会弹一次「网盘管家想要访问钥匙串」的授权框，
    /// 用户点「始终允许」之后就安静了。
    static func systemPassword(host: String, username: String) -> String? {
        guard !host.isEmpty else { return nil }
        for candidate in hostCandidates(host) {
            var query: [String: Any] = [
                kSecClass as String: kSecClassInternetPassword,
                kSecAttrServer as String: candidate,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            if !username.isEmpty { query[kSecAttrAccount as String] = username }
            var out: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
                  let data = out as? Data,
                  let pw = String(data: data, encoding: .utf8),
                  !pw.isEmpty else { continue }
            return pw
        }
        return nil
    }

    /// 同一个 NAS 可能以 IP、主机名、带 .local 等多种形式存过凭据，挨个试。
    ///
    /// 特别注意 `<名字>._smb._tcp.local` 这种形式：用访达挂载（或 `mount volume`）
    /// 时，系统就是把凭据记在这个 server 名下的。少了这一条，「免密码」就永远命中不了。
    private static func hostCandidates(_ host: String) -> [String] {
        var list: [String] = []
        func add(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty && !list.contains(t) { list.append(t) }
        }

        let normalized = Drive.normalizeHost(host)
        add(host)
        add(normalized)

        var bare = normalized
        if bare.lowercased().hasSuffix(".local") { bare = String(bare.dropLast(".local".count)) }

        add(bare + ".local")
        add(bare)
        add(bare + "._smb._tcp.local")
        add(bare + "._afpovertcp._tcp.local")
        add(bare + "._webdav._tcp.local")
        add(bare + "._webdavs._tcp.local")
        return list
    }
}
