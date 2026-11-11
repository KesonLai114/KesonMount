import Foundation

/// 当前所处的网络环境。
///
/// 用来实现「只在自家 Wi-Fi 下才自动挂载」：
/// 笔记本带出门以后，在咖啡厅、在公司里自动去连家里的 NAS，
/// 轻则一直连不上刷一堆错误，重则挂到一台同名的陌生设备上。
/// 所以自动挂载前先问一下「现在在哪张网上」。
///
/// 读 Wi-Fi 名称的坑：macOS 14 起，CoreWLAN 的 `ssid()` 默认把 SSID 抹成
/// `<redacted>`，除非 App 带 `com.apple.developer.networking.wifi-info` 授权
/// （需要正式开发者证书签名，ad-hoc 签名拿不到）。本 App 走 ad-hoc 签名、也没必要
/// 为此去折腾证书，所以改用系统自带的 `networksetup` 命令读——它是 Apple 自己的
/// 特权工具，自带读 Wi-Fi 的权限，不需要本 App 申请定位权限、也不需要 entitlement，
/// 直接就能拿到当前 SSID。拿不到时一律「放行」，绝不因为读不到就把盘卡住。
enum NetworkContext {

    private static let lock = NSLock()
    private static var cachedSSID: String?
    private static var lastRefresh = Date.distantPast
    /// Wi-Fi 接口名（en0/en1…）在硬件不变时是固定的，每次刷新 SSID 都 fork 一次
    /// `networksetup -listallhardwareports` 纯属浪费。缓存住，只在强制刷新时重认。
    private static var cachedWiFiInterface: String?
    private static var didProbeWiFiInterface = false

    /// 当前 Wi-Fi 的名称（SSID）。取不到时返回 nil：
    /// 没连 Wi-Fi、用的是网线、或者 Wi-Fi 接口读不到。
    ///
    /// **只读内存缓存，永远不阻塞调用方**——`snapshot()` 在主线程每几秒就会调它，
    /// 而 `networksetup` 需要 fork 子进程，最坏能干等 30 秒（Wi-Fi 驱动异常时）。
    /// 真实值由 refreshAsync() 在后台刷新。
    static var currentSSID: String? {
        lock.lock(); defer { lock.unlock() }
        return cachedSSID
    }

    /// 后台刷新 SSID（10 秒内的重复调用会被合并）。
    /// 界面、看门狗、启动流程都调这个；值变了会发 .netMountNetworkChanged。
    static func refreshAsync(force: Bool = false) {
        lock.lock()
        let due = force || Date().timeIntervalSince(lastRefresh) >= 10
        if due { lastRefresh = Date() }
        lock.unlock()
        guard due else { return }

        DispatchQueue.global(qos: .utility).async {
            let ssid = fetchSSID()
            lock.lock()
            let changed = cachedSSID != ssid
            cachedSSID = ssid
            lock.unlock()
            guard changed else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .netMountNetworkChanged, object: nil)
            }
        }
    }

    /// 强制刷新缓存（网络刚切换时调用）。顺带作废接口名缓存，
    /// 万一这时插了 USB Wi-Fi 网卡，也能重新认到新的接口。
    static func refresh() {
        lock.lock()
        didProbeWiFiInterface = false
        cachedWiFiInterface = nil
        lock.unlock()
        refreshAsync(force: true)
    }

    /// 找出 Wi-Fi 对应的网络接口（en0 / en1……）。拿不到就回退去试 en0~en3。
    /// 结果缓存住，探测过程不持锁（里面要 fork 一个子进程）。
    private static func wifiInterface() -> String? {
        lock.lock()
        if didProbeWiFiInterface {
            let cached = cachedWiFiInterface
            lock.unlock()
            return cached
        }
        lock.unlock()

        let found = probeWiFiInterface()
        lock.lock()
        didProbeWiFiInterface = true
        cachedWiFiInterface = found
        lock.unlock()
        return found
    }

    private static func probeWiFiInterface() -> String? {
        let r = Shell.run("/usr/sbin/networksetup", ["-listallhardwareports"])
        let lines = r.out.components(separatedBy: .newlines)
        for i in 0..<lines.count {
            if lines[i].contains("Wi-Fi"), i + 1 < lines.count,
               let range = lines[i + 1].range(of: "Device:") {
                let dev = lines[i + 1][range.upperBound...]
                    .trimmingCharacters(in: .whitespaces)
                if !dev.isEmpty { return dev }
            }
        }
        return nil
    }

    /// 用 `networksetup` 读当前 Wi-Fi 的 SSID。
    ///
    /// 之所以不用 CoreWLAN：它需要 `wifi-info` 授权 + 正式签名，否则恒返回 nil。
    /// `networksetup` 是系统工具，天然有权限，绕开了这个坑。
    private static func fetchSSID() -> String? {
        let candidates: [String]
        if let dev = wifiInterface() {
            candidates = [dev]
        } else {
            candidates = (0...3).map { "en\($0)" }
        }
        for iface in candidates {
            let r = Shell.run("/usr/sbin/networksetup",
                              ["-getairportnetwork", iface])
            let out = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            // 已连接： "Current Wi-Fi Network: 我的Wi-Fi"
            // 没连：   "You are not associated with an AirPort network."
            // 非 Wi-Fi 口： "en0 is not a Wi-Fi interface."
            if let range = out.range(of: "Current Wi-Fi Network:") {
                let name = out[range.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { return name }
            }
        }
        return nil
    }

    /// 这块盘在当前网络下是否允许自动挂载。
    ///
    /// - 白名单为空 = 不限制（保持老行为，不给用户添麻烦）
    /// - 取不到 SSID 时放行：宁可多挂一次，也别让用户的盘永远挂不上
    static func allowsAutoMount(_ drive: Drive) -> Bool {
        guard !drive.allowedSSIDs.isEmpty else { return true }
        guard let ssid = currentSSID else { return true }
        return drive.allowedSSIDs.contains { $0.caseInsensitiveCompare(ssid) == .orderedSame }
    }

    /// 没被允许时的原因（给界面显示）；nil 表示没被跳过
    static func skipReason(_ drive: Drive) -> String? {
        guard !drive.allowedSSIDs.isEmpty else { return nil }
        guard let ssid = currentSSID else { return nil }
        if drive.allowedSSIDs.contains(where: { $0.caseInsensitiveCompare(ssid) == .orderedSame }) {
            return nil
        }
        return "当前网络「\(ssid)」不在允许列表里，已跳过自动挂载"
    }

    /// 读不到 Wi-Fi 名称时，给界面一句人话解释（能读到就返回 nil）
    static func ssidUnavailableReason() -> String? {
        if currentSSID != nil { return nil }
        return "当前没有连接 Wi-Fi（用网线 / 热点时识别不了网络），会自动挂载、不做限制。"
    }
}

// MARK: - 网络变化通知

/// 网络环境（Wi-Fi / SSID）发生变化时发出，供界面与自动挂载逻辑刷新。
extension Notification.Name {
    static let netMountNetworkChanged = Notification.Name("netMountNetworkChanged")
}
