# 网盘管家 (NetMount) 项目记忆

## 关键架构决策
- **Wi-Fi SSID 读取**：macOS 14+ 下 CoreWLAN `ssid()` 需要 `com.apple.developer.networking.wifi-info` 授权（正式开发者签名才有，ad-hoc 签名拿不到）。本 App 走 ad-hoc 签名（`build.sh` 用 `codesign -s -`，无 entitlements），故改用 `networksetup -getairportnetwork` 读 SSID，不依赖定位权限/entitlement。**不要改回 CoreWLAN**，除非改为正式签名并加该 entitlement。
- 定位权限（CoreLocation）相关代码已于 2026-10-28 全部移除。
- **不支持服务器根（整台 NAS）挂载**：macOS NetFS 必须知道共享名才挂得出卷，`smb://host/` 从来挂不出可用卷；1.4.4 起移除该路径，当前源码已无 `serverRoot` 分支，`DriveStore.init()` 会清掉老配置里 `share.isEmpty` 的非 NFS 盘。README / 说明书都已统一为此结论。**旧记忆里「整盘卷名 = host 字面量、只用裸 Bonjour 名」是 1.4.4 之前的实现，已作废。** 挂载点固定 `/Volumes/<共享名>`，界面只读展示。
- **版本号唯一来源是 `Resources/Info.plist`**（当前 1.5.0 / 构建 12）；改完跑 `./scripts/sync-version.sh` 同步说明书 HTML。

## 待办 / 已知缺陷

- **第三轮评估（2026-11-11，基线 1.4.5）**：完整清单见 `docs/软件审查报告.md` 第六节（10 项 P0 / 9 项 P1 / 7 项 P2 + 复核无误清单）。**已在 1.5.0 全部落地并验证，不要再按该清单重复修**；实施明细见 `.workbuddy-ai/memory/2026-11-11.md`。

### 1.5.0 已完成（2026-11-11，已构建 + 打包 + 提交，tag `v1.5.0` → `060ba5e`）
- 上面「无法清除已存密码」「WebDAV 强制 HTTPS」两项已修：`clearPassword` + UI 双击确认按钮；`Drive.webdavSecure` + UI「WebDAV 使用 HTTPS」开关。
- 其余落地：Shell 超时强制回收（SIGKILL + `waitUntilExit()` + 关管道）、`MountOps` 串行队列统一挂载/卸载/对账、Keychain 冷启动删盘真删密码、`Diagnostics` 环形日志 + OSLog + 脱敏诊断导出、看门狗状态 prune/换网清理/WOL 幂等、容量 inFlight 去重、局域网发现代次校验、WKWebView 弱引用消息代理、主 ticker `.common`、`NetworkContext` Wi-Fi 接口缓存、文档与实现全面对齐。
- 工程化：git 版本库 + `scripts/check.sh`（5 步）+ `scripts/sync-version.sh` + `tests/main.swift`（75 项断言）+ `.github/workflows/check.yml`（macos-14）；`build.sh`/`package.sh` 按 Info.plist 版本精确取说明书 PDF；删除 `tmpx/_check.swift`。
- 回归测试第 7 组真实 fork /bin 命令验证超时回收、fd 不泄漏、200KB stdin 不死锁、超时不回传带密码 stderr；做过退化版负向验证（3 项断言如期失败），不是假通过。

### 1.4.5 已修复（2026-10-29，已构建 + 打包）
- **自定义挂载点直连已删除**：`viaDirectMount` 会把 `user:pass@` 拼进 `mount_smbfs` / `mount_webdav` 的 argv（同机 `ps` 可见），兜底 `redact` 又只认 `://`。现在只走系统挂载器，统一挂 `/Volumes/<共享名>`；`performMount` 对非 `/Volumes/` 挂载点直接报错，`isSafeMountPoint` 不再放行 `~/Volumes`。
- **只读真实生效**：`connectionURL` 对 `readOnly` 追加 `?rdonly`，挂载后用 `statfs` 的 `MNT_RDONLY` 校验；没挂成只读就自动卸载并报错，不再静默按读写挂。
- **看门狗假重连**：假死盘强制卸载失败时，`mount()` 会命中「已经挂载」早退并返回 ok，`remount` 又丢弃了卸载结果 → 退避清零、每 30 秒循环通知。现在 `remount` 检查卸载结果，仍不可用就判失败。
- **启动自动挂载失败可重试**：`autoMountOnLaunch` 尝试前调 `watchdog.watchForRetry(id)`，失败后由看门狗按指数退避接手。
- **`sourceShare` 解析**：无用户名的 `//host/share` 曾被多剥一级成空串，纳管时被当成服务器根跳过。
- 其余：落点校验改标准化 + 忽略大小写；`Keychain.vault` 加 `NSRecursiveLock`（并发读改写会丢密码）；NFS 提示命令补前导斜杠；`redact` 正则覆盖无 scheme 的 `//user:pass@host`。

### 1.4.4 已修复（2026-10-29）
> 历史记录：其中 `viaDirectMount` 带密码分支、`~/Volumes` 白名单已被 1.4.5 移除，别照着改回去。
- **看门狗掉线后只重试一次**：`wasUp` 每轮被覆写成 `upNow`，掉线的盘第二轮起进不了重连队列。现按「当前未挂载 + `everUp`（本次运行挂过）」筛选候选，退避才真正生效。
- **导入配置端口越界**：`UInt16(...)` 会 trap 崩溃。已在 `Drive.init(from:)` 校验 1...65535，使用点用 `UInt16(exactly:)` 兜底。
- **WebDAV**：`viaOpenURL` 对 webdav 直接返回 nil（`open https://` 只会开浏览器）；`viaDirectMount` 的 webdav 分支补上 `user:pass@host:port`。**`connectionURL` 用 `https://` 传给 AppleScript `mount volume` 是合法的，不要改成 `webdav://`**（旧记录这里是误判）。
- **明文密码进 argv**：`viaSystemMount` 改用 `osascript -` + stdin（`Shell.run(input:)`）；`LANDiscovery.listShares` 删掉带密码分支。
- **主线程阻塞**：`statfs` 容量与 `networksetup` 读 SSID 全部移到后台，`DriveStore.snapshot` / `StatusPopover` 只读缓存（`capacity(for:)`、`NetworkContext.currentSSID` 不再阻塞）。
- **钥匙串静默失败**：`Keychain.save` 改为 update-first 并返回 Bool，写失败会提示用户，不再「先删后加」。
- **`MountScanner.match` 同名共享误判**：第 3 步要求同名卷必须来自同一台服务器（`servers.count == 1`）。
- **探测线程泄漏**：`MountHealth.isHealthy` 对同一 path 最多一个探测在飞。
- **`isSafeMountPoint`**：改为白名单，只接受 `/Volumes/<名>` 与 `~/Volumes/<名>`。
- **`Shell.run` 支持 stdin**：先起 stdout/stderr 读线程再写 stdin，否则「边读边写」的子进程会死锁。

### 仍未处理
- `?rdonly` 是否被 NetFS 透传给 smbfs 尚未在真实 NAS 上验证；若不被接受，只读盘会在挂载后被自动卸载并提示（安全，但功能不可用）。
- 1.5.0 未在真实 NAS 上做端到端挂载回归（只做了编译、静态检查、纯逻辑与 Shell 子进程回归）。
- `StatusBarController.swift:82` 的 `popUpMenu` deprecation warning，不影响功能，warning 不拦检查。

### 已确认的设计取舍（不要再当缺陷改）
- `appMounted` 不持久化：用户确认重启后显示「系统 / 访达挂载」符合预期。
- 访达里手动推出后会被看门狗挂回（`markUserUnmounted` 只在 App 内卸载时调用）。

## 构建 / 验证
- `build.sh`：编译后 `codesign --force --deep --sign -`（ad-hoc 签名），无 entitlements，安装到 /Applications 并同步到「文档库/网盘管家」。
- `package.sh`：通用二进制（x86_64 + arm64）DMG/PKG，产物在 `dist/`；它和 `build.sh` 都按 Info.plist 版本精确取 `docs/网盘管家使用说明书-<版本>.pdf`，别改回按 mtime 挑最新。
- 改代码后跑 `./scripts/check.sh`（Swift 类型检查 / UI JS 语法 / 说明书版本 / action↔原生桥 / 回归测试）。`tests/run.sh` 先把源码 ditto 到本机 /tmp 再编译——SMB 卷上直接编译会报 `input file … was modified during the build`。CI 是 `.github/workflows/check.yml` 的 macos-14 runner，跑同一套。
- 本机执行沙箱禁止启动 `/bin/ps`（`Operation not permitted`），测试里的资源回收检查用 `fcntl` 数 fd + `proc_listchildpids`，不要改成依赖 ps。
