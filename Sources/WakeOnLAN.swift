import Foundation

/// Wake-on-LAN（网络唤醒）。
///
/// 解决的是 NAS 用户最常见的挫败感：设备明明好好的、地址也没错，
/// 就是连不上——因为 NAS 睡着了。网卡支持「魔术包」的话，
/// 发一个特定格式的广播包就能把它叫醒，然后接着挂载。
///
/// 前提是用户在磁盘设置里填了 NAS 的 MAC 地址（局域网发现时可以自动带出来）。
enum WakeOnLAN {

    /// 发魔术包唤醒指定 MAC 的设备。
    ///
    /// 魔术包 = 6 字节 0xFF + 16 次重复的 6 字节 MAC，合计 102 字节。
    /// 端口用 9（discard），几乎所有设备都监听这个端口。
    ///
    /// - Returns: 是否成功发出（发出不代表设备一定会醒）
    @discardableResult
    static func send(mac rawMac: String) -> Bool {
        let mac = Drive.normalizeMAC(rawMac)
        guard !mac.isEmpty else { return false }
        let parts = mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard parts.count == 6 else { return false }

        var packet = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: parts) }

        // 先发全局广播，再发各网段的定向广播——
        // 不少路由器会丢弃 255.255.255.255，但 192.168.x.255 一定通
        var targets = ["255.255.255.255"]
        for b in localBroadcasts() where !targets.contains(b) { targets.append(b) }

        var sent = false
        for target in targets {
            if sendPacket(packet, to: target) { sent = true }
        }
        return sent
    }

    /// 把魔术包发到指定 IP（UDP 广播）
    private static func sendPacket(_ packet: [UInt8], to address: String) -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(9).bigEndian
        guard inet_pton(AF_INET, address, &addr.sin_addr) == 1 else { return false }

        let sent = packet.withUnsafeBytes { raw -> Int in
            withUnsafePointer(to: &addr) { ptr -> Int in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, raw.baseAddress, packet.count, 0, sa,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent == packet.count
    }

    /// 本机各网段的广播地址，例如 192.168.31.255
    static func localBroadcasts() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var out: [String] = []
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let ifa = cur.pointee
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
               let mask = ifa.ifa_netmask {
                var s = sockaddr_in()
                var m = sockaddr_in()
                memcpy(&s, sa, MemoryLayout<sockaddr_in>.size)
                memcpy(&m, mask, MemoryLayout<sockaddr_in>.size)
                let ip = UInt32(bigEndian: s.sin_addr.s_addr)
                let netmask = UInt32(bigEndian: m.sin_addr.s_addr)
                // 广播地址 = IP | ~掩码。直接拼成点分十进制，省掉 getnameinfo 的指针转换
                let broadcast = ip | ~netmask
                let text = "\(broadcast >> 24 & 0xFF).\(broadcast >> 16 & 0xFF).\(broadcast >> 8 & 0xFF).\(broadcast & 0xFF)"
                if !text.isEmpty, !out.contains(text) { out.append(text) }
            }
            p = ifa.ifa_next
        }
        return out
    }

    /// 从系统 ARP 缓存里查某个 IP 对应的 MAC。
    ///
    /// 局域网发现时用得上：设备刚回应过 Bonjour，系统 ARP 表里就有它的 MAC，
    /// 顺手带出来，用户就不用自己抄路由器后台的地址了。
    /// （设备得先跟这台 Mac 打过交道才会有记录，查不到是正常的。）
    static func macAddress(forIP ip: String) -> String? {
        let r = Shell.run("/usr/sbin/arp", ["-n", ip], timeout: 4)
        guard r.ok || !r.out.isEmpty else { return nil }
        for line in r.out.components(separatedBy: "\n") {
            // 形如：? (192.168.31.4) at aa:bb:cc:dd:ee:ff on en0 ifscope [ethernet]
            guard let at = line.range(of: " at ") else { continue }
            let token = line[at.upperBound...]
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .first.map(String.init) ?? ""
            let mac = Drive.normalizeMAC(token)
            if !mac.isEmpty { return mac }
        }
        return nil
    }
}
