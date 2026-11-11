import Foundation
import Darwin

/// 编译时把 Sources/main.swift（App 入口）替换成了本文件，但 MountWatchdog
/// 会读 AppDelegate.isHeadless 来决定要不要跑监控。给一个最小替身：
/// 测试进程里没有 App，恒为 false，且不会启动任何定时器。
enum AppDelegate {
    static let isHeadless = false
}

// 回归测试。
//
// 不启动 App、不碰钥匙串、不发网络请求、不挂载磁盘。前面 6 组验证「写错就会出事」
// 的纯函数：挂载点白名单、外部配置解析、URL 拼装、密码脱敏、shell/AppleScript 转义；
// 第 7 组会真实 fork /bin 下的无害命令，验证 Shell 的超时回收与 stdin 不死锁。
// 由 tests/run.sh 把 Sources（去掉 main.swift）连同本文件编译成一个命令行程序。

private var passed = 0
private var failures: [String] = []

private func ok(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        passed += 1
    } else {
        failures.append("  ✗ \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

private func eq<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
    ok(name, actual == expected, "得到 \(actual)，期望 \(expected)")
}

private func section(_ name: String) { print("▸ \(name)") }

// MARK: - 1. 挂载点白名单

section("1. 挂载点白名单")
ok("留空＝用系统标准位置，合法", Drive.isSafeMountPoint(""))
ok("/Volumes/<共享名> 合法", Drive.isSafeMountPoint("/Volumes/极空间HD"))
ok("/Volumes 下的多级路径合法", Drive.isSafeMountPoint("/Volumes/a/b"))
ok("家目录被拒", !Drive.isSafeMountPoint("/Users/keson/Movies"))
ok("~/Volumes 被拒（该位置只有用户态挂载器能写）", !Drive.isSafeMountPoint("~/Volumes/HD"))
ok("系统目录被拒", !Drive.isSafeMountPoint("/etc"))
ok("单独的 /Volumes 被拒", !Drive.isSafeMountPoint("/Volumes"))
ok("含 .. 被拒", !Drive.isSafeMountPoint("/Volumes/../etc"))
eq("标准挂载点", Drive.standardMountPoint(share: "极空间HD", name: "我的盘"), "/Volumes/极空间HD")
eq("WebDAV 路径取末段当卷名", Drive.standardMountPoint(share: "/remote.php/dav/files/me", name: "云盘"), "/Volumes/me")
eq("共享名里的分隔符被替换", Drive.sanitize("a/b:c"), "a-b-c")

// MARK: - 2. 主机名 / 端口 / MAC

section("2. 主机名 / 端口 / MAC")
eq("去掉 scheme 与尾斜杠", Drive.normalizeHost("smb://Z4S-I0C9.local/"), "Z4S-I0C9.local")
eq("去掉 Bonjour 服务后缀", Drive.normalizeHost("Z4S-I0C9._smb._tcp.local"), "Z4S-I0C9.local")
eq("清掉破坏 URL 结构的字符", Drive.normalizeHost("na\"s'\\x`y"), "nasxy")

let hp = Drive.splitHostPort("nas.local:5006")
eq("拆端口：主机", hp.host, "nas.local")
eq("拆端口：端口", hp.port, 5006)

let hp2 = Drive.splitHostPort("[2001:db8::1]:445")
eq("带方括号 IPv6：主机", hp2.host, "2001:db8::1")
eq("带方括号 IPv6：端口", hp2.port, 445)

let hp3 = Drive.splitHostPort("2001:db8::1")
eq("裸 IPv6 不被误拆", hp3.host, "2001:db8::1")
eq("裸 IPv6 没有端口", hp3.port, Int?.none)
eq("越界端口被忽略", Drive.splitHostPort("nas.local:99999").port, Int?.none)

eq("MAC 连字符写法", Drive.normalizeMAC("aa-bb-cc-dd-ee-ff"), "AA:BB:CC:DD:EE:FF")
eq("MAC 裸 12 位写法", Drive.normalizeMAC("AABBCCDDEEFF"), "AA:BB:CC:DD:EE:FF")
eq("MAC 位数不对返回空", Drive.normalizeMAC("AABB"), "")

// MARK: - 3. 外部配置解码

section("3. 配置解码（外部 JSON 不可信）")
private func decodeDrive(_ json: String) -> Drive? {
    try? JSONDecoder().decode(Drive.self, from: Data(json.utf8))
}

let badPort = decodeDrive(#"{"name":"x","host":"nas.local","share":"HD","port":70000}"#)
ok("越界端口不崩、被丢成 nil", badPort != nil && badPort?.port == nil)

let legacy = decodeDrive(#"{"name":"x","host":"smb://NAS.local/","share":"HD"}"#)
eq("老配置默认 HTTPS", legacy?.webdavSecure, true)
eq("老配置默认自动重挂", legacy?.autoRemount, true)
eq("解码时规范化 host", legacy?.host, "NAS.local")

let modern = decodeDrive(#"{"name":"x","host":"nas","share":"dav","proto":"webdav","webdavSecure":false,"port":5005}"#)
eq("新配置可关闭 HTTPS", modern?.webdavSecure, false)
eq("新配置端口保留", modern?.port, 5005)
eq("新配置协议", modern?.proto, DiskProtocol.webdav)

let hostileHost = decodeDrive(#"{"name":"x","host":"na\"s","share":"HD"}"#)
eq("解码时清掉引号", hostileHost?.host, "nas")

// MARK: - 4. 连接 URL

section("4. 连接 URL 生成")
var d = Drive()
d.proto = .smb
d.host = "192.168.1.10"
d.share = "极空间HD"
let smbURL = MountService.connectionURL(d) ?? ""
ok("SMB scheme 正确", smbURL.hasPrefix("smb://192.168.1.10/"))
ok("中文共享名已百分号编码", !smbURL.contains("极空间"))
ok("URL 里绝不带凭据", !smbURL.contains("@"))

d = Drive()
d.proto = .webdav
d.host = "nas"
d.share = "dav"
d.port = 5005
ok("WebDAV 默认 https", (MountService.connectionURL(d) ?? "").hasPrefix("https://"))
d.webdavSecure = false
let httpURL = MountService.connectionURL(d) ?? ""
ok("关掉 HTTPS 后是 http", httpURL.hasPrefix("http://"))
ok("非默认端口被带上", httpURL.contains(":5005"))

d = Drive()
d.proto = .smb
d.host = "nas"
d.share = "HD"
d.readOnly = true
d.smbVersion = .v21
let optURL = MountService.connectionURL(d) ?? ""
ok("只读参数存在", optURL.contains("rdonly"))
ok("钉死的 SMB 版本存在", optURL.contains("vers=2.1"))
ok("带选项的 URL 也不含凭据", !optURL.contains("@"))

d = Drive()
d.proto = .smb
d.host = "na\"s"
d.share = "HD"
ok("host 里的引号被编码", !(MountService.connectionURL(d) ?? "").contains("\""))
eq("空 host 不生成 URL", MountService.connectionURL(Drive()), String?.none)

// MARK: - 5. 脱敏与注入防护

section("5. 脱敏与注入防护")
ok("smb://user:pass@ 被抹掉", !MountService.redact("连接 smb://alice:s3cr3t@nas/HD 失败").contains("s3cr3t"))
ok("无 scheme 的 //user:pass@ 被抹掉", !MountService.redact("//alice:s3cr3t@nas/HD").contains("s3cr3t"))
ok("AppleScript with password 被抹掉", !MountService.redact("with password \"s3cr3t\" 报错").contains("s3cr3t"))
eq("普通文本不受影响", MountService.redact("找不到服务器 nas.local"), "找不到服务器 nas.local")

eq("shellQuote 普通路径", MountService.shellQuote("/Volumes/HD"), "'/Volumes/HD'")
let quoted = MountService.shellQuote("a'; echo pwned; #")
ok("shellQuote 首尾都是单引号", quoted.hasPrefix("'") && quoted.hasSuffix("'"))
ok("shellQuote 用 '\\'' 断开内部单引号", quoted.contains("'\\''"))
ok("shellQuote 不含裸露的分号拼接", !quoted.contains("a;"))

eq("AppleScript 反斜杠转义", MountService.appleScriptQuote("a\\b"), "a\\\\b")
eq("AppleScript 引号转义", MountService.appleScriptQuote("a\"b"), "a\\\"b")
eq("AppleScript 换行压成空格", MountService.appleScriptQuote("a\nb"), "a b")

// MARK: - 6. 格式化与展示地址

section("6. 格式化与展示地址")
eq("percent 除零保护", Fmt.percent(used: 10, total: 0), 0)
eq("percent 四舍五入", Fmt.percent(used: 755, total: 1000), 76)
ok("bytes 有输出", !Fmt.bytes(1024 * 1024).isEmpty)
eq("未知 SMB 版本回退自动", SMBVersion.from(raw: "9.9"), .auto)
eq("正常 SMB 版本", SMBVersion.from(raw: "3.1.1"), .v311)

var w = Drive()
w.proto = .webdav
w.host = "nas"
w.share = "dav"
eq("WebDAV 默认展示地址", w.address, "https://nas/dav")
w.webdavSecure = false
w.port = 5005
eq("WebDAV HTTP 展示地址", w.address, "http://nas:5005/dav")
eq("协议默认端口", DiskProtocol.webdav.defaultPort, 443)

// MARK: - 7. Shell 子进程回归（真实启动本地命令）
//
// 这一组会真的 fork /bin 下的无害命令，守住 1.5.0 修的几件事：
// ① 超时 kill 后必须 waitUntilExit 回收、并关掉全部管道，否则假死盘每轮卸载超时
//    都会留下挂起的读线程和未关闭的 fd；
// ② stdout/stderr 读句柄要先挂上再写 stdin，否则超过 64KB 管道缓冲就会互相等死；
// ③ 超时不能回传子进程 stderr（osascript 报错时会把带密码的脚本原文吐回来）；
// ④ stdin 为空时接 /dev/null，不然 cat/smbutil 这类命令会一直等输入。
//
// 不用 ps 查僵尸：沙箱里 ps 连启动都会被拒，而 fcntl / proc_listchildpids 只看自己
// 这个进程，本机和 CI 都能跑，也更贴近「有没有把资源还回去」这件事。

private func openFDCount() -> Int {
    var n = 0
    for fd in 0..<1024 where fcntl(Int32(fd), F_GETFD) != -1 { n += 1 }
    return n
}

private func childPIDCount() -> Int {
    var pids = [Int32](repeating: 0, count: 256)
    let n = proc_listchildpids(getpid(), &pids, 256 * 4)
    return max(0, Int(n))
}

section("7. Shell 子进程回归（真实跑本地命令）")

let echo = Shell.run("/bin/echo", ["netmount-ok"], timeout: 5)
eq("echo 退出码", echo.status, 0)
eq("echo 标准输出", echo.out.trimmingCharacters(in: .whitespacesAndNewlines), "netmount-ok")

// 先预热一次，把 Diagnostics / Logger 的一次性初始化排除在基线之外
_ = Shell.run("/bin/sleep", ["4.71"], timeout: 0.3)
let fdBefore = openFDCount()
let childrenBefore = childPIDCount()

var allTimedOut = true
for _ in 0..<4 {
    if Shell.run("/bin/sleep", ["4.71"], timeout: 0.4).status != -2 { allTimedOut = false }
}
ok("连续 4 次超时都返回 -2", allTimedOut)

let fdAfter = openFDCount()
ok("连续超时不泄漏管道 fd", fdAfter <= fdBefore + 2, "之前 \(fdBefore)，之后 \(fdAfter)")
eq("超时子进程已全部回收", childPIDCount(), childrenBefore)
ok("超时后新命令仍能正常执行",
   Shell.run("/bin/echo", ["after-timeout"], timeout: 5).out.contains("after-timeout"))

let leaked = Shell.run("/bin/sh", ["-c", #"echo 'with password "s3cr3t"' >&2; exec sleep 4.72"#], timeout: 0.5)
ok("超时不回传子进程 stderr（可能含密码）", !leaked.err.contains("s3cr3t"))
ok("超时文案固定、不含命令原文", leaked.err.hasPrefix("命令超时（") && !leaked.err.contains("exec sleep"))

let big = String(repeating: "x", count: 200_000)
let roundTrip = Shell.run("/bin/cat", [], timeout: 8, input: big)
eq("200KB stdin 不死锁，全量回显", roundTrip.out.count, big.count)
eq("大 stdin 未超时", roundTrip.status, 0)

let noInput = Shell.run("/bin/cat", [], timeout: 3)
eq("无 input 时接 /dev/null，不会等 stdin", noInput.status, 0)
ok("无 input 时输出为空", noInput.out.isEmpty)

let badUTF8 = Shell.run("/usr/bin/printf", ["\\377abc"], timeout: 5)
ok("非 UTF-8 输出不整体丢空（否则 MountScanner 会误判掉线）",
   badUTF8.out.contains("abc") && badUTF8.out != "\\377abc",
   "得到 \(badUTF8.out.debugDescription)")

// MARK: - 8. 深链接与 NFS 命令
//
// 深链接的输入来自外部（快捷指令、脚本、别的 App），和导入的配置文件一样
// 属于不可信数据：认不出来必须返回 nil，绝不能「猜一个动作」去执行。

section("8. 深链接与 NFS 命令")

let anyID = UUID()

eq("netmount://show", DeepLink.parse("netmount://show"), DeepLink.Command.show)
eq("裸 scheme 等于唤出窗口", DeepLink.parse("netmount:"), DeepLink.Command.show)
eq("大小写不敏感", DeepLink.parse("NETMOUNT://Show"), DeepLink.Command.show)
eq("path 形式也认", DeepLink.parse("netmount:mountAll"), DeepLink.Command.mountAll)
eq("mountAll", DeepLink.parse("netmount://mountAll"), DeepLink.Command.mountAll)
eq("unmountAll", DeepLink.parse("netmount://unmountAll"), DeepLink.Command.unmountAll)
eq("refresh", DeepLink.parse("netmount://refresh"), DeepLink.Command.refresh)
eq("mount?id=", DeepLink.parse("netmount://mount?id=\(anyID.uuidString)"),
   DeepLink.Command.mount(anyID))
eq("unmount?id=", DeepLink.parse("netmount://unmount?id=\(anyID.uuidString)"),
   DeepLink.Command.unmount(anyID))
eq("reconnect?id=", DeepLink.parse("netmount://reconnect?id=\(anyID.uuidString)"),
   DeepLink.Command.reconnect(anyID))
eq("别的 scheme 一律不认", DeepLink.parse("http://mountAll"), DeepLink.Command?.none)
eq("未知动作不认", DeepLink.parse("netmount://formatDisk"), DeepLink.Command?.none)
eq("缺 id 的 mount 不认", DeepLink.parse("netmount://mount"), DeepLink.Command?.none)
eq("id 不是 UUID 不认", DeepLink.parse("netmount://mount?id=1"), DeepLink.Command?.none)
eq("空串不认", DeepLink.parse("   "), DeepLink.Command?.none)

let nfsCmd = MountService.nfsMountCommand(host: "nas.local", export: "/volume1/video",
                                          mountPoint: "/Volumes/video")
eq("NFS 命令格式", nfsCmd, "sudo mount -t nfs 'nas.local:/volume1/video' '/Volumes/video'")
let evilCmd = MountService.nfsMountCommand(host: "nas'; rm -rf /; #", export: "/x",
                                           mountPoint: "/Volumes/x")
ok("NFS 命令里的恶意主机名被单引号锁死", evilCmd.contains("'nas'\\''; rm -rf /; #:/x'"))

// MARK: - 9. 挂载表：系统调用与文本解析必须一致
//
// scan() 现在走 getmntinfo(3)，parse() 是兜底路径。两条路给出的卷必须一样，
// 否则「兜底」会在用户不知情的时候改变行为（少认出一块盘 = 看门狗把它当掉线）。
// 两次读取之间可能真有卷挂上/卸下，所以允许重试。

section("9. 挂载表：getmntinfo 与文本解析一致")

private func mountTables() -> (syscall: [String], text: [String]) {
    let viaSyscall = MountScanner.scan().map(\.path).sorted()
    let raw = Shell.run("/sbin/mount", [], timeout: 8).out
    return (viaSyscall, MountScanner.parse(raw).map(\.path).sorted())
}

var tablesAgree = false
var lastTables: (syscall: [String], text: [String]) = ([], [])
for _ in 0..<3 {
    lastTables = mountTables()
    if lastTables.syscall == lastTables.text { tablesAgree = true; break }
    usleep(200_000)
}
ok("getmntinfo 与 /sbin/mount 解析结果一致", tablesAgree,
   "syscall=\(lastTables.syscall)，text=\(lastTables.text)")

// 挂载表至少能读出「当前真的有网络卷」——这条在本机有 SMB 挂载时才有意义，
// CI 上没有也不该失败，所以只断言「不崩、返回数组」。
let scanned = MountScanner.scan()
ok("scan() 正常返回（不依赖子进程）", scanned.count >= 0)
ok("每块网络卷都有非空挂载点", scanned.allSatisfy { !$0.path.isEmpty && $0.isNetwork })

// MARK: - 结果

print("")
if failures.isEmpty {
    print("✅ 全部通过：\(passed) 项断言")
    exit(0)
} else {
    print("❌ \(failures.count) 项失败 / 共 \(passed + failures.count) 项：")
    for f in failures { print(f) }
    exit(1)
}
