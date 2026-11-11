import Foundation
import Darwin

/// 编译时把 Sources/main.swift（App 入口）替换成了本文件，但 MountWatchdog
/// 会读 AppDelegate.isHeadless 来决定要不要跑监控。给一个最小替身：
/// 测试进程里没有 App，恒为 false，且不会启动任何定时器。
enum AppDelegate {
    static let isHeadless = false
}

// 纯逻辑回归测试。
//
// 不启动 App、不碰钥匙串、不发网络请求、不挂载磁盘，只验证那些「写错就会出事」
// 的纯函数：挂载点白名单、外部配置解析、URL 拼装、密码脱敏、shell/AppleScript 转义。
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
