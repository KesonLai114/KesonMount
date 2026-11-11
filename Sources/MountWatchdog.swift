import AppKit
import Foundation
import UserNotifications

// MARK: - 挂载健康探测

/// 判断一块盘「还活着」。
///
/// 不能只看 mount 表里有没有：SMB 掉线时挂载点常常还挂在表里，界面显示「已挂载」，
/// 但一访问就卡住（soft 挂载要等内核超时才返回错误）。
/// 所以必须真的发一次 I/O —— 读一次根目录就是一次完整的网络往返。
enum MountHealth {

    private static let lock = NSLock()
    /// 正在探测、还没返回的路径。
    ///
    /// 假死的挂载点会把「读目录」卡在内核里很久，而这次读取是没法取消的。
    /// 不记下来，下一轮又会给它新派一个线程，假死一整晚就是几十个
    /// 永久阻塞的线程，最后把全局队列占满。现在同一个 path 最多一个在飞。
    private static var inFlight: Set<String> = []

    static func isHealthy(_ path: String, timeout: TimeInterval = 5) -> Bool {
        guard !path.isEmpty else { return false }

        lock.lock()
        if inFlight.contains(path) {
            // 上一轮那次读还卡在那里：直接当它不健康，不再派新线程
            lock.unlock()
            return false
        }
        inFlight.insert(path)
        lock.unlock()

        let sem = DispatchSemaphore(value: 0)
        var ok = false
        DispatchQueue.global(qos: .utility).async {
            ok = (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
            lock.lock()
            inFlight.remove(path)
            lock.unlock()
            sem.signal()
        }
        // 掉线的挂载点会把这次读取卡住，超时就当它不健康
        if sem.wait(timeout: .now() + timeout) == .timedOut { return false }
        return ok
    }
}

// MARK: - 掉线自动重挂

/// 后台盯着每块盘，掉线了自己接回来。
///
/// 要解决的四件事：
///   1. SMB 隔一阵子自己掉了（路由器重启、NAS 重连、DHCP 换地址）
///   2. 「假死」——挂载点还在，但一访问就卡，用户完全看不出问题
///   3. Mac 休眠 / 唤醒后网络要几秒才回来，这时候直接挂必失败
///   4. NAS 真的关机了 —— 不能每 30 秒无脑重试一次，那是在砸网络
///
/// 所以：探测用真读写、重挂带指数退避、唤醒后等网络稳了再查、失败就拉长间隔。
final class MountWatchdog {

    /// 多久查一轮。30 秒足够及时，又不至于把 NAS 和路由器烦死
    static let defaultInterval: TimeInterval = 30
    /// 退避上限：NAS 关机时最多每 5 分钟试一次
    private static let maxBackoff: TimeInterval = 300

    weak var store: DriveStore?

    let queue = DispatchQueue(label: "netmount.watchdog", qos: .utility)
    /// 重活（扫挂载表、真读写探测）单独一条队列。
    /// 状态队列必须始终保持空闲——界面每秒都可能来问「还要等几秒」，
    /// 它要是被一次 8 秒的 mount 扫描堵住，整个界面就卡死了。
    private let workQueue = DispatchQueue(label: "netmount.watchdog.work", qos: .utility)

    /// watchdog 自己持有的磁盘列表副本，由主线程在状态变化时推进来
    private var drivesCopy: [Drive] = []
    /// 每个磁盘连续重挂失败的次数，用来算退避时间
    private var attempts: [UUID: Int] = [:]
    /// 退避中：下次允许重试的时刻
    private var nextTry: [UUID: Date] = [:]
    /// 本次运行里确认「挂上过」的磁盘。
    ///
    /// 只有它们掉线后才值得重连：从没挂上过的盘（用户刚添加、还没点过挂载）
    /// 不能一启动就被看门狗反手挂上去——那不是「重连」，是替用户做决定。
    private var everUp: Set<UUID> = []
    /// 用户自己卸载的，不能反手给人挂回去
    private var userUnmounted: Set<UUID> = []
    /// 这次掉线已经通知过了，别每轮都弹一次
    private var notifiedDown: Set<UUID> = []
    /// 上一轮还没跑完就不起新一轮
    private var running = false
    /// 已经跑过几轮检查（打日志用）
    private var rounds = 0
    /// 通知授权只问一次
    private static var askedAuth = false
    /// 「正在唤醒」通知去重：设备长期离线时退避封顶后仍每 5 分钟重连一轮，
    /// 不去重就会无限累积系统通知。
    private static let wakeLock = NSLock()
    private static var wakeNotified: Set<UUID> = []
    /// 上一轮看到的 Wi-Fi 名，用来发现「换网了」
    private var lastSSID: String?

    private var timer: DispatchSourceTimer?
    private var tickTimer: DispatchSourceTimer?

    var isRunning: Bool { timer != nil }

    /// 诊断日志：NETMOUNT_LOG=1 时把每一步决策打到标准输出。
    /// 自动重挂是「没人看着的时候自己干活」的功能，出了问题时必须有据可查。
    private func log(_ m: String) {
        // 一直留一份环形记录，用户可一键导出；控制台输出仍由环境变量控制。
        Diagnostics.log("[看门狗] \(m)")
        guard ProcessInfo.processInfo.environment["NETMOUNT_LOG"] == "1" else { return }
        let line = "[看门狗] \(m)\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }

    // MARK: - 启停

    func start() {
        guard timer == nil else { return }
        // 截图 / 自动化调试时不要真的去动用户的磁盘
        // （NETMOUNT_FORCE_WATCHDOG=1 是给自检用的后门：隐身模式下也跑监控）
        guard !AppDelegate.isHeadless
                || ProcessInfo.processInfo.environment["NETMOUNT_FORCE_WATCHDOG"] == "1" else { return }
        guard AppSettings.shared.watchdogEnabled else { return }

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 10, repeating: MountWatchdog.defaultInterval, leeway: .seconds(5))
        t.setEventHandler { [weak self] in self?.checkOnQueue() }
        t.resume()
        timer = t

        // 退避等待期间的秒级心跳：让界面上的「xx 秒后重连」真的在走。
        // 没有盘在退避时这条定时器什么都不做，不会白刷界面。
        let tick = DispatchSource.makeTimerSource(queue: queue)
        tick.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        tick.setEventHandler { [weak self] in
            guard let self, !self.nextTry.isEmpty else { return }
            self.store?.watchdogTick()
        }
        tick.resume()
        tickTimer = tick

        // 休眠唤醒：睡之前网络就断了，醒来后要等 Wi-Fi 重新关联、拿到 IP 才能挂
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(handleWake(_:)),
                           name: NSWorkspace.didWakeNotification, object: nil)
    }

    func stop() {
        timer?.cancel()
        timer = nil
        tickTimer?.cancel()
        tickTimer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    /// 设置里改了开关，或者磁盘列表变了，都可能需要重启一轮
    func restartIfNeeded() {
        let shouldRun = AppSettings.shared.watchdogEnabled && !AppDelegate.isHeadless
        if shouldRun, timer == nil {
            start()
        } else if !shouldRun, timer != nil {
            stop()
        }
    }

    /// 主线程调用：把最新的磁盘列表推进 watchdog 队列
    func updateDrives(_ drives: [Drive]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.drivesCopy = drives
            self.prune(keeping: Set(drives.map(\.id)))
        }
    }

    /// 删盘时把这块盘在看门狗里的状态全部清掉。
    func forget(_ id: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            self.attempts.removeValue(forKey: id)
            self.nextTry.removeValue(forKey: id)
            self.everUp.remove(id)
            self.userUnmounted.remove(id)
            self.notifiedDown.remove(id)
        }
    }

    /// 每轮推进磁盘列表时清掉孤儿键：反复增删盘不该让状态字典单调增长。
    private func prune(keeping ids: Set<UUID>) {
        attempts = attempts.filter { ids.contains($0.key) }
        nextTry = nextTry.filter { ids.contains($0.key) }
        everUp.formIntersection(ids)
        userUnmounted.formIntersection(ids)
        notifiedDown.formIntersection(ids)
    }

    // MARK: - 用户操作登记

    /// 用户手动挂上了：这台归「用户」管，watchdog 只负责它掉线之后的事
    func markUserMounted(_ id: UUID) {
        queue.async { [weak self] in
            self?.userUnmounted.remove(id)
            self?.everUp.insert(id)
            self?.attempts[id] = 0
            self?.nextTry[id] = nil
            self?.notifiedDown.remove(id)
        }
    }

    /// 登记「这块盘应该挂着」：只放进关注集合，不动退避状态。
    ///
    /// 启动自动挂载用得上：第一次尝试往往因为刚登录、网络还没就绪而失败，
    /// 登记之后看门狗才会按指数退避接手重试。不能直接用 markUserMounted——
    /// 那会清空退避，而这时盘很可能还没挂上。
    func watchForRetry(_ id: UUID) {
        queue.async { [weak self] in
            self?.everUp.insert(id)
        }
    }

    /// 用户手动卸载了：记住，别自动挂回去
    func markUserUnmounted(_ id: UUID) {
        queue.async { [weak self] in
            self?.userUnmounted.insert(id)
            self?.everUp.remove(id)
            self?.attempts[id] = 0
            self?.nextTry[id] = nil
            self?.notifiedDown.remove(id)
        }
    }

    // MARK: - 休眠 / 唤醒

    @objc private func handleWake(_ note: Notification) {
        queue.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self else { return }
            // 刚睡醒，把退避清零，让重试立刻开始
            self.attempts.removeAll()
            self.nextTry.removeAll()
            self.notifiedDown.removeAll()
            self.checkOnQueue()
        }
    }

    /// 每轮检查前对一下「现在在哪张 Wi-Fi 上」。
    ///
    /// 换网意味着之前所有失败都可能是「当时不在对的地方」，退避必须清零；
    /// 同时让「只在某些 Wi-Fi 下挂载」的盘重新评估——否则早上出门被跳过，
    /// 晚上回到家还得等最多 5 分钟（退避上限）才被重连，甚至一直不重连。
    private func detectNetworkChange() {
        // SSID 只在后台刷新，这里读上一次的值；下一轮（30 秒后）才能看到新值，
        // 对「换网后补挂」来说完全够用，也不会把状态队列堵在子进程上。
        NetworkContext.refreshAsync()
        let ssid = NetworkContext.currentSSID
        guard ssid != lastSSID else { return }
        let previous = lastSSID
        lastSSID = ssid
        attempts.removeAll()
        nextTry.removeAll()
        // 换网后如果盘仍然掉线，要允许重新发一次掉线通知；
        // 之前漏清这一项会让 notifiedDown 永远卡住。
        notifiedDown.removeAll()
        log("网络变化：\(previous ?? "无") → \(ssid ?? "无")，退避已清零")
        // 通知界面 / 其他模块：网络变了，重新评估按 Wi-Fi 挂载的盘
        NotificationCenter.default.post(name: .netMountNetworkChanged, object: nil)
        // 两边都为空说明本来就没网，不用惊动主线程
        guard previous != nil || ssid != nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.store?.retryNetworkSkipped()
        }
    }

    // MARK: - 主检查

    /// 主线程或队列都能调，统一收敛到 watchdog 队列上跑
    func checkNow() {
        if Thread.isMainThread {
            queue.async { [weak self] in self?.checkOnQueue() }
        } else {
            checkOnQueue()
        }
    }

    private func checkOnQueue() {
        guard !running else { return }
        guard store != nil else { return }
        guard AppSettings.shared.watchdogEnabled else { return }
        guard !AppDelegate.isHeadless
                || ProcessInfo.processInfo.environment["NETMOUNT_FORCE_WATCHDOG"] == "1" else { return }

        running = true
        // 先看是不是换网了：换网要清零退避，并让被网络策略跳过的盘重新评估
        detectNetworkChange()
        // 这两份状态只在状态队列上改，派活的时候直接拷走，工作队列就能放心读
        let drives = drivesCopy
        let skipped = userUnmounted
        // 只盯「这次运行里确实挂上过」的盘，避免把用户没打算挂的盘挂上去
        let watched = everUp

        // 扫描 + 探测都慢，放到工作队列上跑，别占着状态队列
        workQueue.async { [weak self] in
            let volumes = MountScanner.scan()
            self?.log("第 \(self?.rounds ?? 0) 轮：扫到 \(volumes.count) 个网络卷，盯着 \(drives.count) 块盘")

            var upNow: Set<UUID> = []
            var downNow: [Drive] = []
            var stale: [(Drive, MountedVolume)] = []

            for drive in drives where drive.autoRemount
                && !skipped.contains(drive.id)
                && watched.contains(drive.id) {
                guard let v = MountScanner.match(drive: drive, in: volumes) else {
                    // 挂载表里没有它，就是该连而没连上。
                    // 关键：候选只看「现在挂没挂上」，绝不能用「上一轮还活着」来筛——
                    // 那样掉线的盘从第二轮起就不在集合里了，recover 再也不会被调用，
                    // 指数退避和界面倒计时全成了死代码。
                    downNow.append(drive)
                    continue
                }
                upNow.insert(drive.id)
                // 挂着不等于活着，真读一次才知道
                if !MountHealth.isHealthy(v.path) { stale.append((drive, v)) }
            }

            self?.queue.async {
                guard let self else { return }
                self.running = false
                self.rounds += 1
                self.log("活着 \(upNow.count) 块；掉线 \(downNow.count) 块；假死 \(stale.count) 块")
                for drive in downNow {
                    self.announce(drive, "连接已断开，正在自动重连")
                    self.recover(drive, stale: nil)
                }
                for (drive, v) in stale {
                    self.announce(drive, "连接已失去响应，正在重新挂载")
                    self.recover(drive, stale: v)
                }
            }
        }
    }

    /// 掉线只通知一次，重连成功再通知一次；期间的重试不再刷屏。
    ///
    /// 这一轮开始，每轮检查都会对所有「未挂载」的盘调用 recover，所以这里必须幂等：
    /// 否则一块盘掉线后会每 30 秒弹一条 toast + 一条系统通知。
    private func announce(_ drive: Drive, _ message: String) {
        guard !notifiedDown.contains(drive.id) else { return }
        notifiedDown.insert(drive.id)
        log("「\(drive.name)」\(message)")
        store?.noteWatchdog(drive, message: message)
        Self.notify(title: "「\(drive.name)」掉线了", body: MountService.redact(message))
    }

    // MARK: - 重挂

    private func recover(_ drive: Drive, stale: MountedVolume?) {
        guard let store else { return }
        guard AppSettings.shared.watchdogEnabled else { return }

        // 退避中：先记一笔，等时间到了再说。
        // 只写日志、不推 toast——界面上的倒计时由 retryState() 直接读 nextTry 算出来，
        // 每 30 秒刷一条「还要等 N 秒」纯属打扰。
        if let next = nextTry[drive.id], Date() < next {
            let left = Int(next.timeIntervalSinceNow.rounded(.up))
            let failed = attempts[drive.id, default: 0]
            log("「\(drive.name)」退避中，还要等 \(left) 秒（已失败 \(failed) 次）")
            return
        }

        let n = attempts[drive.id, default: 0]
        let backoff = min(MountWatchdog.maxBackoff, 30 * pow(2, Double(n)))
        nextTry[drive.id] = Date().addingTimeInterval(backoff)
        attempts[drive.id] = n + 1
        log("「\(drive.name)」开始第 \(n + 1) 次重连，失败的话 \(Int(backoff)) 秒后再试")

        store.remount(drive, reason: "自动重连", forceUnmountVolume: stale) { [weak self] ok in
            self?.queue.async {
                guard ok, let self else { return }
                // 连上了：退避清零，通知一次「回来了」
                self.attempts[drive.id] = 0
                self.nextTry[drive.id] = nil
                self.everUp.insert(drive.id)
                self.userUnmounted.remove(drive.id)
                self.log("「\(drive.name)」重连成功")
                if self.notifiedDown.remove(drive.id) != nil {
                    Self.notify(title: "「\(drive.name)」已重新连接", body: "自动重连成功")
                }
            }
        }
    }

    // MARK: - 给界面看的状态

    struct RetryState {
        var retrying: Bool
        var secondsLeft: Int
    }

    /// 主线程调用：这块盘是不是正在退避等待
    func retryState(for id: UUID) -> RetryState {
        if Thread.isMainThread {
            return queue.sync { retryStateOnQueue(for: id) }
        }
        return retryStateOnQueue(for: id)
    }

    private func retryStateOnQueue(for id: UUID) -> RetryState {
        guard let next = nextTry[id], next > Date() else {
            return RetryState(retrying: false, secondsLeft: 0)
        }
        return RetryState(retrying: true, secondsLeft: Int(next.timeIntervalSinceNow.rounded(.up)))
    }

    /// 主线程调用：给设置面板看的总览
    func statusSnapshot() -> [String: Any] {
        if Thread.isMainThread {
            return queue.sync { statusSnapshotOnQueue() }
        }
        return statusSnapshotOnQueue()
    }

    private func statusSnapshotOnQueue() -> [String: Any] {
        var retrying: [String] = []
        for (id, next) in nextTry where next > Date() {
            retrying.append(id.uuidString)
        }
        return [
            "enabled": AppSettings.shared.watchdogEnabled,
            "interval": Int(MountWatchdog.defaultInterval),
            // 报「设了自动重挂的盘数」而不是「上一轮确认活着的盘数」——
            // 后者在第一轮检查跑完前是 0，界面上会显示成「没在监控」
            "watching": drivesCopy.filter { $0.autoRemount }.count,
            "retrying": retrying.sorted()
        ]
    }

    // MARK: - 系统通知

    /// 发一条系统通知。做成 static：挂载层（MountService）需要它，
    /// 但那里拿不到 DriveStore 手上的 watchdog 实例。
    static func notify(title: String, body: String) {
        guard AppSettings.shared.notifyEvents else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                MountWatchdog.post(title: title, body: body)
            case .notDetermined:
                guard !askedAuth else { return }
                askedAuth = true
                center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
                    if ok { MountWatchdog.post(title: title, body: body) }
                }
            default:
                // 用户关掉了通知：界面上的 toast 一样能看到，不打扰他
                break
            }
        }
    }

    /// 唤醒通知按盘去重，直到真正连上（clearWakeNotification）才允许再发。
    static func notifyWakeOnce(drive: Drive, title: String, body: String) {
        wakeLock.lock()
        let fresh = wakeNotified.insert(drive.id).inserted
        wakeLock.unlock()
        guard fresh else { return }
        Diagnostics.log("「\(drive.name)」发送网络唤醒包")
        notify(title: title, body: body)
    }

    static func clearWakeNotification(_ id: UUID) {
        wakeLock.lock()
        wakeNotified.remove(id)
        wakeLock.unlock()
    }

    private static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = MountService.redact(body)
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
