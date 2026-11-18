import Foundation

final class DriveStore {

    private(set) var drives: [Drive] = []
    private(set) var volumes: [MountedVolume] = []
    private(set) var busy: Set<UUID> = []
    var errors: [UUID: String] = [:]
    var toast: String?

    /// 状态变化时回调（保证在主线程）
    var onChange: (() -> Void)?

    private let fm = FileManager.default
    private var didSeed = false
    private var toastToken = 0
    private var passwordCache: [UUID: Bool] = [:]
    /// 正在后台查「有没有存密码」的盘，避免重复排队
    private var passwordPending: Set<UUID> = []
    private var systemCredCache: [String: Bool] = [:]
    /// 正在后台查的 host，避免重复排队
    private var credPending: Set<String> = []
    /// 用户主动删掉的磁盘（host|share），下次启动不再自动导回来
    private var dismissed: Set<String> = []
    /// 本次运行里由KesonMount 自己挂上的磁盘（用来区分「谁挂的」）
    private var appMounted: Set<UUID> = []
    /// 因为不在允许的 Wi-Fi 里而被跳过自动挂载的盘（界面上要标出来）
    private(set) var networkSkipped: Set<UUID> = []
    /// 掉线自动重挂的后台盯梢
    let watchdog = MountWatchdog()

    /// 容量缓存。`statfs` 对失去响应的网络卷会一直阻塞，绝不能在主线程调；
    /// 后台每 10 秒算一次，snapshot（主线程）只读这里。
    private var capacityCache: [UUID: (total: Int64, free: Int64)] = [:]
    private var lastCapacityRefresh = Date.distantPast
    /// 上一轮 statfs 还没回来：假死卷会永久阻塞，必须防止每 10 秒再派一个线程。
    private var capacityInFlight = false
    /// 本进程上次写 drives.json 的时间，用来识别「运行时被外部手改」。
    private var configWrittenAt: Date?
    /// 配置文件解码失败时的备份文件名（启动后提示用户）
    private var configLoadFailed: String?

    /// 是否已保存密码。
    ///
    /// **只读缓存，绝不在调用线程上碰钥匙串**：`SecItemCopyMatching` 在钥匙串被锁、
    /// 或用户第一次授权时会一直阻塞到有人点掉那个系统对话框——而这个方法会被
    /// `snapshot()` 在主线程每几秒调一次，一卡就是整个界面冻住。
    /// 没缓存时先按「没有」返回，后台查完再 notify 一次刷新界面。
    func hasPassword(_ drive: Drive) -> Bool {
        if let cached = passwordCache[drive.id] { return cached }
        warmPasswordState(for: drive)
        return false
    }

    /// 后台查「这块盘有没有存过密码」，结果进缓存
    private func warmPasswordState(for drive: Drive) {
        guard !passwordPending.contains(drive.id) else { return }
        passwordPending.insert(drive.id)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let has = Keychain.hasPassword(for: drive)
            DispatchQueue.main.async {
                guard let self else { return }
                self.passwordPending.remove(drive.id)
                if self.passwordCache[drive.id] != has {
                    self.passwordCache[drive.id] = has
                    self.notify()
                }
            }
        }
    }

    /// 让缓存失效并在后台重新查一次。
    /// 挂载过程可能刚从系统钥匙串继承了密码，缓存里的「没有」已经不准了。
    private func invalidatePasswordCache(for drive: Drive) {
        passwordCache[drive.id] = nil
        warmPasswordState(for: drive)
    }

    /// 凭据来源：saved（KesonMount存的）/ system（系统里存过，可直接沿用）/ none
    ///
    /// 只读缓存，绝不在主线程跑 `security`——查系统钥匙串要走子进程，
    /// 一次查 8 个候选名会把界面卡住小半秒。没缓存就先返回 none，
    /// 后台查完再 notify 一次刷新界面。
    func credentialSource(_ drive: Drive) -> String {
        if hasPassword(drive) { return "saved" }
        if drive.proto == .nfs { return "none" }
        if let cached = systemCredCache[drive.host] { return cached ? "system" : "none" }
        warmSystemCredential(host: drive.host)
        return "none"
    }

    /// 后台查「系统钥匙串里有没有这台服务器的凭据」，结果进缓存
    private func warmSystemCredential(host: String) {
        guard !host.isEmpty, !credPending.contains(host) else { return }
        credPending.insert(host)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let has = Keychain.hasSystemCredential(host: host)
            DispatchQueue.main.async {
                guard let self else { return }
                self.credPending.remove(host)
                if self.systemCredCache[host] != has {
                    self.systemCredCache[host] = has
                    self.notify()
                }
            }
        }
    }

    private func ignoreKey(host: String, share: String) -> String {
        "\(Drive.normalizeHost(host).lowercased())|\(share.lowercased())"
    }

    // MARK: - 路径

    private var supportDir: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("KesonMount", isDirectory: true)
    }

    /// 改名前的配置目录；只在首次启动且新目录还没有配置时读取并迁移。
    private var legacySupportDir: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("NetMount", isDirectory: true)
    }

    private func migrateLegacyConfigIfNeeded() {
        guard !fm.fileExists(atPath: configURL.path) else { return }
        let old = legacySupportDir.appendingPathComponent("drives.json")
        guard fm.fileExists(atPath: old.path) else { return }
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        for name in ["drives.json", "dismissed.json"] {
            let src = legacySupportDir.appendingPathComponent(name)
            let dst = supportDir.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { continue }
            do {
                try fm.copyItem(at: src, to: dst)
                try? fm.removeItem(at: src)
            } catch {
                // 拷不过去就保留旧文件，下次启动再试；绝不覆盖已有新配置
                break
            }
        }
    }

    private var configURL: URL {
        supportDir.appendingPathComponent("drives.json")
    }

    private var dismissedURL: URL {
        supportDir.appendingPathComponent("dismissed.json")
    }

    // MARK: - 初始化

    init() {
        watchdog.store = self
        // 通知里的「立即重连」按钮要有人接：必须尽早挂上委托，
        // 否则用户点按钮时系统找不到处理者，点了等于没点。
        NotificationRouter.shared.install(store: self)
        // SSID 要提前在后台读：1.2 秒后 autoMountOnLaunch 就要用它判断能不能挂。
        // 现在 currentSSID 只读缓存，启动时不预热就永远是 nil（= 放行）。
        NetworkContext.refreshAsync(force: true)
        migrateLegacyConfigIfNeeded()
        load()
        // 清掉老版本自动纳管的「服务器根」盘：没有共享名的 smb/webdav 盘在 macOS 上
        // 永远挂不出来（NetFS 必须知道共享名才挂得出卷），留着每次启动只会报错。
        // 这类盘是 adoptableVolumes 自己造的，不是用户填的——表单也不允许共享名为空。
        let stale = drives.filter { $0.proto != .nfs && $0.share.isEmpty }
        if !stale.isEmpty {
            for d in stale { Keychain.delete(for: d) }
            drives.removeAll { $0.proto != .nfs && $0.share.isEmpty }
            persist()
        }
        loadDismissed()
        scanNow()
        seedIfNeeded()
        // 启动这一刻已经挂着的盘，要告诉 watchdog「它本来是好的」：
        // 否则启动时没挂的盘永远进不了 everUp，之后掉了也不会被发现
        // （启动时就没挂的盘不 seed——那是用户主动卸的，不能反手挂回去）
        for drive in drives where volume(for: drive) != nil {
            watchdog.markUserMounted(drive.id)
        }
        watchdog.start()
        refreshCapacitiesIfNeeded()
        if let bad = configLoadFailed {
            show("配置文件读取失败，已备份为 \(bad)；本次从空配置启动，可尝试「导入配置」恢复")
        }
        // 收拾历史遗留重复挂载的任务由 autoMountOnLaunch 收尾时排进 MountOps
        // 串行队列（见下方）。旧版用固定 8 秒延时「等挂载完成」，而一次挂载最长
        // 可到 30 秒，两边会同时动同一块盘。
    }

    /// 把磁盘列表同步给 watchdog。
    /// watchdog 跑在自己的串行队列上，而 drives 只在主线程改，
    /// 所以由主线程在每次状态变化时推一份过去，两边不直接抢同一份数据。
    func pushDrivesToWatchdog() {
        watchdog.updateDrives(drives)
    }

    // MARK: - 配置读写

    private func load() {
        guard let data = try? Data(contentsOf: configURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if var list = try? decoder.decode([Drive].self, from: data) {
            // 本地文件也可能被手改或被别的工具写过：和表单 / 导入一样过校验，
            // 不能只信 decoder——任意 mountPoint 会直接流到挂载流程里。
            var changed = false
            for i in list.indices {
                if !Drive.isSafeMountPoint(list[i].mountPoint) {
                    list[i].mountPoint = ""
                    changed = true
                }
                if list[i].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    list[i].name = list[i].share.isEmpty ? "网络磁盘" : list[i].share
                    changed = true
                }
            }
            drives = list
            configWrittenAt = fileModificationDate()
            // 老配置里存着 ~/Volumes/... 这类自定义挂载点，升级时清掉
            if migrateLegacyMountPoints() { changed = true }
            if changed { persist() }
            return
        }
        // 解码失败绝不能静默当成「没有配置」：任意一次 persist()（改设置、导入、
        // 记住 IP）都会把原文件直接覆盖，用户的挂载点就永久没了。先把现场留一份。
        let backup = configURL.deletingLastPathComponent()
            .appendingPathComponent("drives.json.corrupt-\(Int(Date().timeIntervalSince1970))")
        try? fm.copyItem(at: configURL, to: backup)
        configLoadFailed = backup.lastPathComponent
    }

    private func fileModificationDate() -> Date? {
        guard let attrs = try? fm.attributesOfItem(atPath: configURL.path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        return date
    }

    /// 老版本默认把盘挂到 `~/Volumes/<名称>`，和系统的 `/Volumes/<共享名>` 各挂一份，
    /// 桌面上就多出一倍图标，两边路径还各是各的。
    /// 升级后把这些自定义挂载点清空，统一回到系统标准位置——路径才稳定。
    private func migrateLegacyMountPoints() -> Bool {
        let legacyRoot = NSHomeDirectory() + "/Volumes/"
        var changed = false
        for i in drives.indices where drives[i].mountPoint.hasPrefix(legacyRoot) {
            drives[i].mountPoint = ""
            changed = true
        }
        return changed
    }

    private func loadDismissed() {
        guard let data = try? Data(contentsOf: dismissedURL),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return }
        dismissed = Set(list)
    }

    private func persistDismissed() {
        do {
            try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Array(dismissed).sorted())
            try data.write(to: dismissedURL, options: .atomic)
        } catch {
            // 这份名单丢了只是可能多导一次，不值得打扰用户
        }
    }

    private func persist() {
        do {
            // App 运行时若有人手改了 drives.json，旧逻辑会用内存状态静默覆盖，
            // 改的那几块盘就凭空消失（本项目已经出过一次这样的事故）。
            // 先把外部那份留个备份再写，并明确告诉用户。
            if let written = configWrittenAt, let onDisk = fileModificationDate(),
               onDisk.timeIntervalSince(written) > 1.0 {
                let backup = configURL.deletingLastPathComponent()
                    .appendingPathComponent("drives.json.external-\(Int(Date().timeIntervalSince1970))")
                try? fm.copyItem(at: configURL, to: backup)
                show("检测到配置文件在 App 运行时被外部修改，已备份为 \(backup.lastPathComponent)")
            }
            try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(drives).write(to: configURL, options: .atomic)
            configWrittenAt = fileModificationDate() ?? Date()
        } catch {
            show("保存配置失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 状态

    func refresh() {
        // 扫描要 fork `/sbin/mount` 子进程，绝不能占着主线程——
        // 否则每 4 秒卡一下，拖动窗口时尤其明显。
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let scanned = MountScanner.scan()
            DispatchQueue.main.async {
                guard let self else { return }
                // 没变化就不通知，省掉一次无谓的界面重绘
                if self.volumes != scanned {
                    self.volumes = scanned
                    self.notify()
                }
            }
        }
        refreshCapacitiesIfNeeded()
    }

    /// 后台重算已挂载盘的容量（10 秒节流）。
    ///
    /// `attributesOfFileSystem` 就是 statfs(2)：对失去响应的 SMB 挂载点会一直阻塞，
    /// 所以只能放在后台算。主线程（snapshot / 菜单栏面板）一律读缓存。
    private func refreshCapacitiesIfNeeded() {
        guard !capacityInFlight else { return }
        guard Date().timeIntervalSince(lastCapacityRefresh) >= 10 else { return }
        capacityInFlight = true
        lastCapacityRefresh = Date()
        // 要算哪些卷先在主线程定下来，后台只碰这份值类型副本
        let targets: [(UUID, MountedVolume)] = drives.compactMap { drive in
            guard let v = volume(for: drive) else { return nil }
            return (drive.id, v)
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var result: [UUID: (total: Int64, free: Int64)] = [:]
            for (id, v) in targets {
                if let cap = v.capacity { result[id] = cap }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.capacityInFlight = false
                let old = self.capacityCache
                let changed = old.count != result.count || old.contains { id, cap in
                    result[id]?.total != cap.total || result[id]?.free != cap.free
                }
                self.capacityCache = result
                // 没变化就不推界面，避免每 10 秒无谓重绘一次
                if changed { self.notify() }
            }
        }
    }

    /// 同步扫一次（仅初始化用：启动时就要有正确状态）
    private func scanNow() {
        volumes = MountScanner.scan()
    }

    private func notify() {
        if Thread.isMainThread {
            pushDrivesToWatchdog()
            onChange?()
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pushDrivesToWatchdog()
                self.onChange?()
            }
        }
    }

    /// 扫挂载表要 fork /sbin/mount，任何情况下都不占主线程。
    private func refreshVolumesAsync() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let scanned = MountScanner.scan()
            DispatchQueue.main.async {
                guard let self else { return }
                self.volumes = scanned
                self.notify()
            }
        }
    }

    /// 把系统里已挂载、但还没纳管的网络磁盘补进来。
    /// 每次启动都跑一次——这样即使这次是通过访达挂的，也会被记住，卸载后记录还在。
    private func seedIfNeeded() {
        guard !didSeed else { return }
        didSeed = true
        syncMountedDrives(announce: false)
    }

    @discardableResult
    private func syncMountedDrives(announce: Bool) -> Int {
        volumes = MountScanner.scan()

        // 已纳管但没记挂载点的盘（老配置）：把这次实际挂在哪补记下来。
        // 记下之后重挂就认这个位置，用户的文件路径才不会因为系统把新卷改名成
        // 「…-1」而静默失效。
        var patched = false
        for i in drives.indices where drives[i].mountPoint.isEmpty {
            if let v = MountScanner.match(drive: drives[i], in: volumes) {
                drives[i].mountPoint = v.path
                patched = true
            }
        }
        if patched { persist() }

        let candidates = MountScanner.adoptableVolumes(volumes: volumes, known: drives)
            .filter { !dismissed.contains(ignoreKey(host: $0.host, share: $0.share)) }
        guard !candidates.isEmpty else {
            if announce { show("没有发现新的已挂载网络磁盘") }
            return 0
        }
        drives.append(contentsOf: candidates)
        persist()
        // 趁现在磁盘是挂着的、网络通着，把 IP 先解析好存起来：
        // 下次挂载直接用 IP，省掉 .local 那 5～10 秒的解析等待
        for d in candidates { rememberIP(for: d) }
        if announce { show("已导入 \(candidates.count) 块网络磁盘") }
        return candidates.count
    }

    func importMountedDrives() {
        _ = syncMountedDrives(announce: true)
        notify()
        // 顺手收拾刚导入可能带来的重复挂载（访达那份 + KesonMount那份）
        reconcileMounts()
    }

    // MARK: - 重复挂载 / 老位置迁移

    /// 收拾「同一块共享挂了好几份」的局面。
    ///
    /// 桌面上四个硬盘图标就是这么来的：老版本KesonMount把盘挂到 `~/Volumes`，
    /// 访达（或者用户自己连的那次）又挂到 `/Volumes`，同一块共享两份。
    /// 这里只摘明确多余的那几个（`~/Volumes` 下的、系统重复挂出的 `xxx-1`），
    /// 正牌的 `/Volumes/<共享名>` 永远留着；正在被占用、摘不动的就跳过，下次再说。
    ///
    /// 另外把「只挂在老位置」的盘搬到标准位置：摘下来，按新逻辑重挂一次，
    /// 这样它的路径从此固定在 `/Volumes/<共享名>`，用户在别处配的路径不会再失效。
    func reconcileMounts(announce: Bool = false) {
        // 状态只在主线程读，快照带进串行队列；真正动挂载表的工作也排同一条队列，
        // 于是启动自动挂载 / 看门狗重连 / 用户点击 / 这里绝不会同时动一块盘。
        let snapshot = drives
        let busyIDs = busy
        MountOps.run { [weak self] in
            self?.reconcileMountsOnQueue(snapshot: snapshot, busyIDs: busyIDs,
                                          announce: announce)
        }
    }

    /// 只在 MountOps.queue 上执行。
    private func reconcileMountsOnQueue(snapshot: [Drive], busyIDs: Set<UUID>,
                                        announce: Bool) {
        var removed = 0
        for v in MountScanner.redundant(in: MountScanner.scan()) {
            if case .ok = MountService.unmount(v) { removed += 1 }
        }

        // 只在老位置（~/Volumes）挂着的盘：挪到系统标准位置
        let legacyRoot = NSHomeDirectory() + "/Volumes/"
        let volumes = MountScanner.scan()
        var migrated = 0
        for drive in snapshot where !busyIDs.contains(drive.id) {
            guard let v = MountScanner.match(drive: drive, in: volumes),
                  v.path.hasPrefix(legacyRoot) else { continue }
            let oldPath = v.path
            guard case .ok = MountService.unmount(v) else { continue }
            if case .ok = MountService.mount(drive) {
                migrated += 1
            } else {
                // 新位置没挂上（认证失败、网络抖动等）：把卷挂回老位置，
                // 别让它凭空消失——盘还在配置里，但用户眼前至少还有个能用的卷。
                var restore = drive
                restore.mountPoint = oldPath
                _ = MountService.mount(restore)
                migrated += 1
            }
        }

        let latest = MountScanner.scan()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.volumes = latest
            if removed > 0 {
                self.show("已清理 \(removed) 个重复挂载（同一块共享只留一个）")
            } else if migrated > 0 {
                self.show("已把 \(migrated) 块磁盘挪到系统标准位置 /Volumes")
            } else if announce {
                self.show("没有发现重复挂载")
            }
            self.notify()
        }
    }

    // MARK: - 查询

    func volume(for drive: Drive) -> MountedVolume? {
        MountScanner.match(drive: drive, in: volumes)
    }

    /// 主线程安全：容量只读缓存，绝不碰 statfs
    func capacity(for drive: Drive) -> (total: Int64, free: Int64)? {
        guard volume(for: drive) != nil else { return nil }
        return capacityCache[drive.id]
    }

    func drive(id: UUID) -> Drive? {
        drives.first { $0.id == id }
    }

    // MARK: - 增删改

    func upsert(_ drive: Drive, password: String?) {
        var passwordSaveFailed = false
        if let password, !password.isEmpty {
            passwordSaveFailed = !Keychain.save(password: password, for: drive)
            // 没写进去就别缓存「有密码」——否则界面会给出错误判断
            if passwordSaveFailed {
                invalidatePasswordCache(for: drive)
            } else {
                passwordCache[drive.id] = true
            }
        }
        // 手动加回来的，就别再拦着自动导入了
        let key = ignoreKey(host: drive.host, share: drive.share)
        if dismissed.remove(key) != nil { persistDismissed() }

        if let idx = drives.firstIndex(where: { $0.id == drive.id }) {
            drives[idx] = drive
        } else {
            drives.append(drive)
        }
        persist()
        if passwordSaveFailed {
            show("已保存「\(drive.name)」，但密码没能写入钥匙串（可能已锁定），请解锁后重新填写")
        } else {
            show("已保存「\(drive.name)」")
        }
        self.refreshVolumesAsync()
    }

    /// 明确清除已存密码。编辑框留空表示「不修改」，所以必须有独立入口。
    func clearPassword(for id: UUID) {
        guard let drive = self.drive(id: id) else { return }
        Keychain.delete(for: drive)
        passwordCache[id] = false
        show("已清除「\(drive.name)」保存的密码")
        notify()
    }

    func remove(_ drive: Drive) {
        // 先摘掉界面上的记录，卸载放后台跑——diskutil 最坏能卡 25 秒，
        // 同步跑会把主线程冻住半个分钟
        Keychain.delete(for: drive)
        passwordCache[drive.id] = nil
        watchdog.forget(drive.id)
        appMounted.remove(drive.id)
        networkSkipped.remove(drive.id)
        // 记一笔，免得下次启动又把它当成"新发现的已挂载磁盘"导回来
        dismissed.insert(ignoreKey(host: drive.host, share: drive.share))
        persistDismissed()
        drives.removeAll { $0.id == drive.id }
        errors[drive.id] = nil
        persist()
        show("已移除「\(drive.name)」")

        // 卸载是慢动作，放后台；失败了也不回滚「已移除」——记录已经没了，
        // 用户手动去访达断开即可，不值得为这再弹一次错误
        MountOps.run { [weak self] in
            guard let self else { return }
            // 重新扫一次，避免 volumes 缓存还没刷新导致漏卸
            if let v = MountScanner.match(drive: drive, in: MountScanner.scan()) {
                _ = MountService.unmount(v)
            }
            DispatchQueue.main.async {
                self.refreshVolumesAsync()
            }
        }
    }

    func toggleAutoMount(_ drive: Drive) {
        guard let idx = drives.firstIndex(where: { $0.id == drive.id }) else { return }
        drives[idx].autoMount.toggle()
        persist()
        show(drives[idx].autoMount ? "已开启启动自动挂载" : "已关闭启动自动挂载")
        notify()
    }

    func toggleAutoRemount(_ drive: Drive) {
        guard let idx = drives.firstIndex(where: { $0.id == drive.id }) else { return }
        drives[idx].autoRemount.toggle()
        persist()
        show(drives[idx].autoRemount ? "已开启掉线自动重挂" : "已关闭掉线自动重挂")
        notify()
    }

    /// 用户手动要求「立即重新连接一次」。
    /// 假死的挂载点会在后台探出来，自动走强制卸载，不会卡在转圈上。
    func reconnectNow(_ drive: Drive) {
        remount(drive, reason: "手动重连")
    }

    // MARK: - 挂载 / 卸载

    func mount(_ drive: Drive) {
        guard !busy.contains(drive.id) else { return }
        // 手动挂载了就不再是「被网络策略跳过」的状态，清掉标记，
        // 否则卡片会同时显示「已挂载」和「已跳过」两个矛盾标签
        networkSkipped.remove(drive.id)
        busy.insert(drive.id)
        errors[drive.id] = nil
        notify()

        MountOps.run {
            let result = MountService.mount(drive)
            DispatchQueue.main.async {
                self.busy.remove(drive.id)
                switch result {
                case .ok(let message):
                    // 挂载过程中可能刚从系统钥匙串继承了密码，让缓存重新查一次
                    self.invalidatePasswordCache(for: drive)
                    self.systemCredCache[drive.host] = nil
                    // 记下来：这次是KesonMount 自己挂的
                    self.appMounted.insert(drive.id)
                    self.watchdog.markUserMounted(drive.id)
                    self.show(message)
                    self.rememberIP(for: drive)
                case .fail(let message):
                    // 兜底脱敏：任何路径漏出来的连接串都不允许把密码带到界面上
                    self.errors[drive.id] = MountService.redact(message)
                    // 认证失败是最容易忽略、又最容易修的问题，单独提醒一次
                    if message.contains("账号或密码") || message.lowercased().contains("authentication") {
                        MountWatchdog.notify(
                            title: "「\(drive.name)」认证失败",
                            body: "账号或密码不正确，请编辑这块磁盘的密码后重试"
                        )
                    }
                }
                self.refreshVolumesAsync()
            }
        }
    }

    /// 挂载成功后把解析到的 IP 记下来。下次挂载直接用它，不用再等主机名解析。
    private func rememberIP(for drive: Drive) {
        guard drive.ipHint == nil, drive.host.contains("."), drive.proto != .nfs else { return }
        DispatchQueue.global(qos: .utility).async {
            // 双网卡 NAS 会解析出两个地址，挑真能连上的那个存
            // 按协议选端口：SMB 探 445、WebDAV 探 443，别都拿 445 去撞
            guard let ip = LANDiscovery.bestIP(drive.host, port: UInt16(drive.proto.defaultPort)) else { return }
            DispatchQueue.main.async {
                guard let idx = self.drives.firstIndex(where: { $0.id == drive.id }) else { return }
                guard self.drives[idx].ipHint == nil else { return }
                self.drives[idx].ipHint = ip
                self.persist()
            }
        }
    }

    func unmount(_ drive: Drive) {
        guard let v = volume(for: drive), !busy.contains(drive.id) else { return }
        busy.insert(drive.id)
        errors[drive.id] = nil
        notify()

        MountOps.run {
            // privileged: 用户主动点的卸载，NFS 这类 root 挂的卷可以弹一次授权框；
            // 看门狗自动重连那条路径不传，后台绝不弹框。
            let result = MountService.unmount(v, privileged: true)
            DispatchQueue.main.async {
                self.busy.remove(drive.id)
                switch result {
                case .ok(let message):
                    self.appMounted.remove(drive.id)
                    // 用户自己卸的，watchdog 不许反手挂回去
                    self.watchdog.markUserUnmounted(drive.id)
                    self.show(message)
                case .fail(let message): self.errors[drive.id] = MountService.redact(message)
                }
                self.refreshVolumesAsync()
            }
        }
    }

    func toggleMount(_ drive: Drive) {
        if volume(for: drive) != nil {
            unmount(drive)
        } else {
            mount(drive)
        }
    }

    func autoMountOnLaunch() {
        let pending = drives.filter { $0.autoMount && volume(for: $0) == nil }
        var skipped: [Drive] = []
        for drive in pending {
            // 只在允许的 Wi-Fi 下才自动挂载。出门在外就别去连家里的 NAS 了，
            // 免得刷一堆连不上的错误
            guard NetworkContext.allowsAutoMount(drive) else {
                networkSkipped.insert(drive.id)
                skipped.append(drive)
                continue
            }
            // 登录瞬间网络常常还没就绪，这一次挂不上很常见。先把盘登记进看门狗的
            // 关注集合，失败后才会按指数退避接着重试；不登记的话「启动自动挂载」
            // 只要失败一次就再也没人管它了。
            watchdog.watchForRetry(drive.id)
            mount(drive)
        }
        if !skipped.isEmpty {
            let names = skipped.map(\.name).joined(separator: "、")
            show("已跳过 \(skipped.count) 块盘（不在当前网络）：\(names)")
        }
        // 排在本次所有自动挂载任务之后（同一串行队列），不再靠固定延时猜。
        reconcileMounts()
    }

    /// 网络换了（比如从公司回到家）：把之前因为「不在允许的 Wi-Fi」而跳过的盘
    /// 重新评估一次，能挂的立刻挂上。
    ///
    /// 没有这一步，Wi-Fi 白名单就只是一次性的启动过滤器：早上在家启动被挂上，
    /// 白天带出门被跳过，晚上回来还得自己手动点一遍——那就不叫自动挂载了。
    func retryNetworkSkipped() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.retryNetworkSkipped() }
            return
        }
        let candidates = drives.filter {
            networkSkipped.contains($0.id) && $0.autoMount && volume(for: $0) == nil
        }
        guard !candidates.isEmpty else { return }

        var started = 0
        for drive in candidates {
            guard NetworkContext.allowsAutoMount(drive) else { continue }
            networkSkipped.remove(drive.id)
            mount(drive)          // mount() 里会清跳过标记并 notify
            started += 1
        }
        if started > 0 {
            show("已进入允许的网络，正在挂载 \(started) 块磁盘…")
        }
    }

    /// 一次挂上所有还没挂的盘
    func mountAll() {
        let pending = drives.filter { volume(for: $0) == nil }
        guard !pending.isEmpty else {
            show("全部磁盘都已挂载")
            return
        }
        for drive in pending { mount(drive) }
        show("正在挂载 \(pending.count) 块磁盘…")
    }

    /// 一次卸掉所有已挂载的盘
    func unmountAll() {
        let mounted = drives.filter { volume(for: $0) != nil }
        guard !mounted.isEmpty else {
            show("当前没有已挂载的磁盘")
            return
        }
        for drive in mounted { unmount(drive) }
        show("正在卸载 \(mounted.count) 块磁盘…")
    }

    // MARK: - 配置备份 / 迁移

    /// 导出的配置文件。密码不在里面（密码存在钥匙串，不导出）
    struct ConfigBackup: Codable {
        var appVersion: String
        var exportedAt: Date
        var drives: [Drive]
    }

    /// 把全部磁盘配置导出成一个 JSON 文件（备份 / 换机用）
    func exportConfig(to url: URL) throws -> Int {
        let backup = ConfigBackup(appVersion: AppInfo.version, exportedAt: Date(), drives: drives)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(backup).write(to: url, options: .atomic)
        return drives.count
    }

    /// 从 JSON 备份导入配置。
    ///
    /// 按 id 合并而不是整份替换：文件里有的覆盖同 id 的盘，新的追加，
    /// 文件里没提到的老盘保留。这样「导出一份改改再导回来」也不会把别的盘弄丢。
    @discardableResult
    func importConfig(from url: URL) throws -> (added: Int, updated: Int) {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let incoming: [Drive]
        if let backup = try? decoder.decode(ConfigBackup.self, from: data) {
            incoming = backup.drives
        } else {
            // 也接受直接就是一份盘列表的格式
            incoming = try decoder.decode([Drive].self, from: data)
        }

        var added = 0
        var updated = 0
        for var drive in incoming {
            // 安全：导入的是外部 JSON 文件，挂载点必须过和表单一样的校验。
            // 否则一个伪造的备份文件就能把盘挂到 /etc、/System 这类系统目录。
            if !Drive.isSafeMountPoint(drive.mountPoint) {
                drive.mountPoint = ""
            }
            // 名字兜底：空名会让挂载点退化成 ~/Volumes/网络磁盘，多块盘会撞在一起
            if drive.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                drive.name = drive.share.isEmpty ? "网络磁盘" : drive.share
            }
            if let idx = drives.firstIndex(where: { $0.id == drive.id }) {
                let old = drives[idx]
                // 密码按盘 id 存：导入若把 host / 用户名改了，旧密码不能继续
                // 被拿去连那台新主机（伪造备份借此可以把凭据导向别处）。
                if Drive.normalizeHost(old.host) != Drive.normalizeHost(drive.host)
                    || old.username != drive.username {
                    Keychain.delete(for: drive)
                    passwordCache[drive.id] = false
                }
                drives[idx] = drive
                updated += 1
            } else {
                drives.append(drive)
                added += 1
            }
        }
        persist()
        self.refreshVolumesAsync()
        return (added, updated)
    }

    // MARK: - 掉线自动重挂

    /// watchdog 发现这块盘掉了 / 假死了，重新连一次。
    /// - Parameters:
    ///   - forceUnmountVolume: 假死时挂载点还在，普通卸载会一直转圈，必须先强制摘掉
    ///   - completion: 重连是否成功（watchdog 用它清退避、发通知）
    func remount(_ drive: Drive, reason: String, forceUnmountVolume: MountedVolume? = nil,
                 completion: ((Bool) -> Void)? = nil) {
        // watchdog 是从自己的后台队列调进来的，而下面要改 networkSkipped / busy /
        // errors 这几个「只在主线程改」的状态。不先回主线程就是并发改 Set，
        // 轻则状态错乱（界面显示连接中但永远不结束），重则直接崩。
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.remount(drive, reason: reason,
                              forceUnmountVolume: forceUnmountVolume,
                              completion: completion)
            }
            return
        }
        // 不在允许的网络里就别重连了——出门在外一直去连家里 NAS 只会一直失败
        guard NetworkContext.allowsAutoMount(drive) else {
            networkSkipped.insert(drive.id)
            // 要通知一次，否则界面上不会出现「已跳过」这个状态，
            // 用户只看到一块永远「未挂载」的盘，不知道为什么
            notify()
            completion?(false)
            return
        }
        networkSkipped.remove(drive.id)
        guard !busy.contains(drive.id) else {
            completion?(false)
            return
        }
        busy.insert(drive.id)
        errors[drive.id] = nil
        notify()
        // volumes 只在主线程整体赋值，后台读它属于跨线程访问；
        // 快照先在这里取好，后面全程只用它。
        let currentVolume = volume(for: drive)

        MountOps.run { [weak self] in
            guard let self else { return }
            // 假死的挂载点要先摘掉，否则 mount() 看到「已经挂载」就直接返回。
            // 这里再探一次：健康的挂载点走普通卸载（安全），
            // 已经失去响应的才走强制卸载，否则会一直转圈。
            let needsForce: MountedVolume?
            if let given = forceUnmountVolume {
                needsForce = given
            } else if let v = currentVolume, !MountHealth.isHealthy(v.path) {
                needsForce = v
            } else {
                needsForce = nil
            }
            var unmountFailed = false
            if let v = needsForce ?? currentVolume {
                if case .fail = MountService.unmount(v, force: needsForce != nil) {
                    unmountFailed = true
                    usleep(300_000)
                }
            }
            // 卸载没成功、盘还在挂载表里且仍然读不动时，mount() 会命中「已经挂载」
            // 那条早退并返回成功——那只是「它还在」，不是「它好了」。这种假成功会把
            // 退避清零，于是每 30 秒重来一次、每 30 秒弹一对通知，而盘始终是死的。
            if unmountFailed,
               let still = MountScanner.match(drive: drive, in: MountScanner.scan()),
               !MountHealth.isHealthy(still.path) {
                DispatchQueue.main.async {
                    self.busy.remove(drive.id)
                    self.errors[drive.id] = MountService.redact(
                        "卸载失败：磁盘仍挂在 \(still.path) 但已失去响应，请手动推出后重试"
                    )
                    completion?(false)
                    self.refreshVolumesAsync()
                }
                return
            }
            let result = MountService.mount(drive)
            DispatchQueue.main.async {
                self.busy.remove(drive.id)
                switch result {
                case .ok(let message):
                    self.invalidatePasswordCache(for: drive)
                    self.systemCredCache[drive.host] = nil
                    self.appMounted.insert(drive.id)
                    self.show("\(reason)，已重新连接（\(message)）")
                    self.rememberIP(for: drive)
                    completion?(true)
                case .fail(let message):
                    self.errors[drive.id] = MountService.redact(message)
                    completion?(false)
                }
                self.refreshVolumesAsync()
            }
        }
    }

    /// watchdog 记一笔：掉了、假死了、还在退避等待。
    /// watchdog 从自己的队列调进来，show() 会改 toast，必须回主线程。
    func noteWatchdog(_ drive: Drive, message: String) {
        let text = "「\(drive.name)」\(message)"
        if Thread.isMainThread {
            show(text)
        } else {
            DispatchQueue.main.async { [weak self] in self?.show(text) }
        }
    }

    /// watchdog 的秒级心跳：只在退避等待期间调用，让界面上的倒计时真的在走
    func watchdogTick() {
        notify()
    }

    // MARK: - 连接诊断

    private var diagnosing: Set<UUID> = []
    private var diagnoseLog: [UUID: [String]] = [:]

    func isDiagnosing(_ drive: Drive) -> Bool { diagnosing.contains(drive.id) }

    func diagnoseLog(for drive: Drive) -> [String] { diagnoseLog[drive.id] ?? [] }

    /// 依次试各个 SMB 协议版本，找出能连上的那个，并直接存进磁盘设置里
    func diagnose(_ drive: Drive) {
        guard !diagnosing.contains(drive.id) else { return }
        diagnosing.insert(drive.id)
        diagnoseLog[drive.id] = []
        notify()

        MountService.diagnoseSMB(drive, progress: { [weak self] line in
            guard let self else { return }
            DispatchQueue.main.async {
                self.diagnoseLog[drive.id, default: []].append(line)
                self.notify()
            }
        }, completion: { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                self.diagnosing.remove(drive.id)
                self.diagnoseLog[drive.id, default: []].append(contentsOf: result.log)

                if let working = result.workingVersion {
                    if let idx = self.drives.firstIndex(where: { $0.id == drive.id }),
                       self.drives[idx].smbVersion != working {
                        self.drives[idx].smbVersion = working
                        self.persist()
                        self.show("已把「\(drive.name)」的协议版本改成 \(working.title)")
                    } else {
                        self.show("「\(drive.name)」用 \(working.title) 就能连上")
                    }
                } else {
                    self.show("诊断完成：没能连上，请看详细记录")
                }
                self.refreshVolumesAsync()
            }
        })
    }

    // MARK: - 打开 / 复制

    func revealPath(for drive: Drive) -> String {
        if let v = volume(for: drive) { return v.path }
        return drive.resolvedMountPoint
    }

    // MARK: - 提示

    func show(_ message: String) {
        toastToken += 1
        let token = toastToken
        toast = MountService.redact(message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, self.toastToken == token else { return }
            self.toast = nil
            self.notify()
        }
    }

    // MARK: - 生成给前端的状态

    func snapshot() -> [String: Any] {
        var list: [[String: Any]] = []
        var totalBytes: Int64 = 0
        var usedBytes: Int64 = 0
        var mountedCount = 0

        for drive in drives {
            let v = volume(for: drive)
            // 只读缓存：statfs 在对假死的网络盘会一直阻塞，绝不能在主线程调
            let cap = v == nil ? nil : capacityCache[drive.id]
            let total = cap?.total ?? 0
            let used = (cap?.total ?? 0) - (cap?.free ?? 0)
            if v != nil { mountedCount += 1 }
            if total > 0 {
                totalBytes += total
                usedBytes += used
            }

            // 挂载来源：这块盘当前是谁挂上去的、实际用的是什么地址
            let origin: String
            let originText: String
            if v == nil {
                origin = ""
                originText = ""
            } else if appMounted.contains(drive.id) {
                origin = "app"
                originText = "KesonMount挂载"
            } else {
                origin = "system"
                originText = "系统 / 访达挂载"
            }

            // 掉线后正在退避等待？界面要显示「xx 秒后重试」
            let retry = watchdog.retryState(for: drive.id)

            var item: [String: Any] = [
                "id": drive.id.uuidString,
                "name": drive.name,
                "proto": drive.proto.rawValue,
                "protoTitle": drive.proto.title,
                "host": drive.host,
                "share": drive.share,
                "username": drive.username,
                "port": drive.port ?? 0,
                "address": drive.address,
                "mountPoint": drive.resolvedMountPoint,
                "mountPointRaw": drive.mountPoint,
                "path": v?.path ?? "",
                "mounted": v != nil,
                "busy": busy.contains(drive.id),
                "autoMount": drive.autoMount,
                "autoRemount": drive.autoRemount,
                "smbVersion": drive.smbVersion.rawValue,
                "smbVersionTitle": drive.smbVersion.title,
                "retrying": retry.retrying,
                "retryIn": retry.secondsLeft,
                "diagnosing": isDiagnosing(drive),
                "diagnoseLog": diagnoseLog(for: drive),
                "readOnly": drive.readOnly,
                "webdavSecure": drive.webdavSecure,
                "note": drive.note,
                "imported": drive.imported,
                // 网络唤醒用：NAS 网卡的 MAC
                "macAddress": drive.macAddress ?? "",
                // 只在这些 Wi-Fi 下自动挂载
                "allowedSSIDs": drive.allowedSSIDs,
                "networkSkipped": networkSkipped.contains(drive.id),
                "networkSkipReason": NetworkContext.skipReason(drive) ?? "",
                "hasPassword": hasPassword(drive),
                "credential": credentialSource(drive),
                // 系统里的真实挂载信息（未挂载时为空串）
                "mountOrigin": origin,
                "mountOriginText": originText,
                "mountSource": MountService.redact(v?.source ?? ""),
                "mountServer": v?.host ?? "",
                "mountUser": MountService.redact(v?.userName ?? ""),
                "mountFsTitle": v?.fsTitle ?? "",
                "total": total,
                "used": used,
                "free": cap?.free ?? 0,
                "percent": Fmt.percent(used: used, total: total),
                "totalText": total > 0 ? Fmt.bytes(total) : "",
                "usedText": total > 0 ? Fmt.bytes(used) : "",
                "freeText": total > 0 ? Fmt.bytes(cap?.free ?? 0) : ""
            ]
            if let err = errors[drive.id] { item["error"] = err }
            list.append(item)
        }

        return [
            "drives": list,
            "mountedCount": mountedCount,
            "count": drives.count,
            "totalBytes": totalBytes,
            "usedBytes": usedBytes,
            "totalText": totalBytes > 0 ? Fmt.bytes(totalBytes) : "",
            "usedText": usedBytes > 0 ? Fmt.bytes(usedBytes) : "",
            "watchdog": watchdog.statusSnapshot(),
            "toast": toast ?? "",
            // 版本号直接摆在界面上，用户不用再自己去翻安装包
            "version": AppInfo.version,
            "build": AppInfo.build,
            "versionText": AppInfo.full,
            // 当前所在的 Wi-Fi（给「只在家挂载」用）
            "currentSSID": NetworkContext.currentSSID ?? "",
            // 读不到 Wi-Fi 名称时的一句人话解释（能读到就是空串）
            "ssidReason": NetworkContext.ssidUnavailableReason() ?? "",
            "hotkeys": HotkeyManager.describe(),
            "hotkeyTrusted": HotkeyManager.shared.isTrusted
        ]
    }
}
