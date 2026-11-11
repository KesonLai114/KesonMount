# 网盘管家 (NetMount) 项目记忆

## 关键架构决策
- **Wi-Fi SSID 读取**：macOS 14+ 下 CoreWLAN `ssid()` 需要 `com.apple.developer.networking.wifi-info` 授权（正式开发者签名才有，ad-hoc 签名拿不到）。本 App 走 ad-hoc 签名（`build.sh` 用 `codesign -s -`，无 entitlements），故改用 `networksetup -getairportnetwork` 读 SSID，不依赖定位权限/entitlement。**不要改回 CoreWLAN**，除非改为正式签名并加该 entitlement。
- 定位权限（CoreLocation）相关代码已于 2026-10-28 全部移除。
- **整盘（服务器根）挂载的卷名 = URL 里 host 字面量**：`smb://Z4S-I0C9/` → 卷 `Z4S-I0C9`；`smb://Z4S-I0C9.local/` → 卷 `Z4S-I0C9.local`；`smb://IP/` → 卷 `IP`。用户只要裸 Bonjour 名 `Z4S-I0C9` 整 NAS 卷，**不要 `.local`、不要 IP 卷**。所以 serverRoot 盘挂载候选只用裸名，绝不退回 IP/`.local`（见 `MountService.mount()`）。共享挂载卷名是共享名，不受此影响。

## 待办 / 已知缺陷

- **第三轮评估（2026-11-11，基线 1.4.5）**：完整清单见 `docs/软件审查报告.md` 第六节（10 项 P0 / 9 项 P1 / 7 项 P2 + 复核无误清单）。当时只评估、未改源码。优先修：Shell 超时不回收子进程、reconcileMounts 无互斥、Keychain 冷启动删盘漏删密码、WebDAV 强制 HTTPS、README/说明书与实现脱节、无 git 与无测试。

### 1.4.5 已修复（2026-10-29，已构建 + 打包）
- **自定义挂载点直连已删除**：`viaDirectMount` 会把 `user:pass@` 拼进 `mount_smbfs` / `mount_webdav` 的 argv（同机 `ps` 可见），兜底 `redact` 又只认 `://`。现在只走系统挂载器，统一挂 `/Volumes/<共享名>`；`performMount` 对非 `/Volumes/` 挂载点直接报错，`isSafeMountPoint` 不再放行 `~/Volumes`。
- **只读真实生效**：`connectionURL` 对 `readOnly` 追加 `?rdonly`，挂载后用 `statfs` 的 `MNT_RDONLY` 校验；没挂成只读就自动卸载并报错，不再静默按读写挂。
- **看门狗假重连**：假死盘强制卸载失败时，`mount()` 会命中「已经挂载」早退并返回 ok，`remount` 又丢弃了卸载结果 → 退避清零、每 30 秒循环通知。现在 `remount` 检查卸载结果，仍不可用就判失败。
- **启动自动挂载失败可重试**：`autoMountOnLaunch` 尝试前调 `watchdog.watchForRetry(id)`，失败后由看门狗按指数退避接手。
- **`sourceShare` 解析**：无用户名的 `//host/share` 曾被多剥一级成空串，纳管时被当成服务器根跳过。
- 其余：落点校验改标准化 + 忽略大小写；`Keychain.vault` 加 `NSRecursiveLock`（并发读改写会丢密码）；NFS 提示命令补前导斜杠；`redact` 正则覆盖无 scheme 的 `//user:pass@host`。

### 1.4.4 已修复（2026-10-29）
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
- 无法清除已存密码（`upsert` 只在密码非空时写入）——只有删除整块盘才会清钥匙串条目。
- WebDAV 的 URL 仍硬编码 `https://`，纯 HTTP（如 5005 端口）的 WebDAV 配不了。
- `?rdonly` 是否被 NetFS 透传给 smbfs 尚未在真实 NAS 上验证；若不被接受，只读盘会在挂载后被自动卸载并提示（安全，但功能不可用）。

### 已确认的设计取舍（不要再当缺陷改）
- `appMounted` 不持久化：用户确认重启后显示「系统 / 访达挂载」符合预期。
- 访达里手动推出后会被看门狗挂回（`markUserUnmounted` 只在 App 内卸载时调用）。

## 构建
- `build.sh`：编译后 `codesign --force --deep --sign -`（ad-hoc 签名），无 entitlements，安装到 /Applications 并同步到「文档库/网盘管家」。
