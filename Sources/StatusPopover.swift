import AppKit

/// 菜单栏弹窗：点一下状态栏图标就弹出来的那块面板。
///
/// 用途是「不用切到主窗口，也能一眼看到每块盘的状态、顺手挂载或卸载」。
/// AutoMounter、Mountain 都是这个交互——菜单栏 App 的主战场就在这儿。
///
/// 视觉走「卡片 + 状态胶囊」的路子：
///   · 头部：App 图标 + 标题 + 版本号
///   · 概览：已挂载几个 + 一条细进度条
///   · 列表：每块盘一张圆角卡片，悬停高亮，状态胶囊 + 容量条
///   · 底部：主按钮（强调色）+ 次按钮
///
/// 布局全部用 frame 手算，不用 Auto Layout：
/// 面板宽高都是固定值（360 × N），手算结果 100% 可预测，
/// 不会出现约束冲突、拉伸跑偏、跨 macOS 版本表现不一致的问题。
final class StatusPopoverController: NSViewController {

    private let store: DriveStore

    /// 面板宽度。StatusBarController 建 NSPopover 时也用这个值，两边必须一致。
    static let panelWidth: CGFloat = 360
    /// 内容区宽度（面板宽度减去左右留白）
    private static let contentWidth: CGFloat = panelWidth - 28

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "网盘管家")
    private let versionLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let overviewBar = CapacityBar()
    /// 列表容器：卡片按 frame 自上而下排
    private var listContainer: FlippedContainer!

    // 各区块的引用：面板高度随磁盘数量变化时，靠它们重排（见 layoutContent）
    private var headerView: NSView!
    private var overviewView: NSView!
    private var separator1: SeparatorLine!
    private var scrollView: NSScrollView!
    private var separator2: SeparatorLine!
    private var footerView: NSView!

    private var timer: Timer?
    /// 列表区高度约束（磁盘数量变了要改它，否则新加的盘被挤在一条缝里）
    private var scrollHeight: NSLayoutConstraint?
    /// 列表内容高度约束：NSStackView 靠它告诉滚动视图「内容有多高」
    private var listContentHeight: NSLayoutConstraint?
    /// 上一次算出来的面板高度，用来判断要不要通知外层改 NSPopover.contentSize
    private var lastHeight: CGFloat = 0
    /// 列表内容的指纹。定时刷新时只有内容真变了才重建列表，
    /// 否则每 2 秒重排一次会把悬停高亮和滚动位置全弄丢。
    private var listSignature = ""

    // MARK: - 尺寸常量

    private enum Metric {
        static let pad: CGFloat = 14          // 面板左右留白
        static let headerH: CGFloat = 22     // 头部高度
        static let overviewH: CGFloat = 26   // 概览区高度
        static let footerH: CGFloat = 60     // 底部两行按钮
        static let rowGap: CGFloat = 8       // 卡片之间间距
        static let cardPad: CGFloat = 12     // 卡片内左右留白
        static let iconSize: CGFloat = 30    // 协议图标底块
        static let btnW: CGFloat = 54        // 挂载/卸载按钮宽度
        static let btnH: CGFloat = 24
        static let cardHWithBar: CGFloat = 64
        static let cardHPlain: CGFloat = 52
    }

    // MARK: - 尺寸计算

    /// 这块盘有没有容量信息（决定卡片要不要画容量条）
    private func hasCapacity(_ drive: Drive) -> Bool {
        guard let cap = store.capacity(for: drive) else { return false }
        return cap.total > 0
    }

    /// 列表区高度：按每张卡片的实际高度累加，封顶 320（再多就滚动）
    private var listHeight: CGFloat {
        let drives = store.drives
        guard !drives.isEmpty else { return 84 }   // 空状态的高度
        let gap = CGFloat(max(drives.count - 1, 0)) * Metric.rowGap
        let total = drives.reduce(CGFloat(0)) { $0 + cardHeight(for: $1) } + gap + 4
        return min(total, 320)
    }

    private func cardHeight(for drive: Drive) -> CGFloat {
        hasCapacity(drive) ? Metric.cardHWithBar : Metric.cardHPlain
    }

    /// 列表内容的完整高度（滚动视图据此算滚动范围）
    private var listContentHeightValue: CGFloat {
        let drives = store.drives
        guard !drives.isEmpty else { return 80 }
        let gap = CGFloat(max(drives.count - 1, 0)) * Metric.rowGap
        return drives.reduce(CGFloat(0)) { $0 + cardHeight(for: $1) } + gap
    }

    /// 整个面板的首选高度，给 NSPopover.contentSize 用（不用等 view 加载）
    var preferredHeight: CGFloat { 190 + listHeight }

    var onOpenWindow: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onMountAll: (() -> Void)?
    var onUnmountAll: (() -> Void)?
    /// 面板高度需要变时回调（外层据此改 NSPopover.contentSize）
    var onResize: ((NSSize) -> Void)?

    init(store: DriveStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 视图

    override func loadView() {
        let H = preferredHeight
        let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: H))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        headerView = makeHeader()
        overviewView = makeOverview()
        separator1 = SeparatorLine()
        scrollView = makeScroll()
        separator2 = SeparatorLine()
        footerView = makeFooter()

        for v in [headerView, overviewView, separator1, scrollView, separator2, footerView] as [NSView] {
            v.autoresizingMask = []
            container.addSubview(v)
        }

        view = container
        layoutContent(height: H)
        refresh()
    }

    /// 按给定总高度重新摆放所有区块。
    ///
    /// 面板高度会随磁盘数量变化（NSPopover.contentSize 被改小/改大）。
    /// 子视图是按「当前高度」用绝对 frame 从顶往下排的，高度变了若不重排，
    /// 顶部区块会停在旧 y 坐标上、被新窗口裁掉——表现为「上半部分没显示」。
    /// 所以高度一变（增或减），这里把所有区块重新摆一遍，保证始终贴合窗口。
    private func layoutContent(height H: CGFloat) {
        let W = Self.contentWidth
        var top: CGFloat = Metric.pad

        headerView.frame = NSRect(x: Metric.pad, y: H - top - Metric.headerH, width: W, height: Metric.headerH)
        top += Metric.headerH + 12

        overviewView.frame = NSRect(x: Metric.pad, y: H - top - Metric.overviewH, width: W, height: Metric.overviewH)
        top += Metric.overviewH + 10

        separator1.frame = NSRect(x: Metric.pad, y: H - top - 1, width: W, height: 1)
        top += 1 + 10

        scrollView.frame = NSRect(x: Metric.pad, y: H - top - listHeight, width: W, height: listHeight)
        top += listHeight + 10

        separator2.frame = NSRect(x: Metric.pad, y: H - top - 1, width: W, height: 1)
        top += 1 + 12

        footerView.frame = NSRect(x: Metric.pad, y: H - top - Metric.footerH, width: W, height: Metric.footerH)

        scrollHeight?.constant = listHeight
        listContentHeight?.constant = listContentHeightValue
    }

    // MARK: - 头部

    private func makeHeader() -> NSView {
        let header = NSView()

        // 优先用 App 图标；拿不到（比如图标还没生成）就退回 SF Symbol
        if let appIcon = NSApp.applicationIconImage, appIcon.size.width > 0 {
            iconView.image = appIcon
            iconView.imageScaling = .scaleProportionallyDown
        } else {
            iconView.image = NSImage(systemSymbolName: "externaldrive.fill",
                                      accessibilityDescription: nil)
            iconView.contentTintColor = .controlAccentColor
            iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        }
        iconView.frame = NSRect(x: 0, y: 0, width: Metric.iconSize - 8, height: Metric.iconSize - 8)
        iconView.autoresizingMask = []

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .left
        let titleW = titleLabel.sizeThatFits(NSSize(width: 9999, height: 20)).width
        titleLabel.frame = NSRect(x: Metric.iconSize - 8 + 8, y: 2, width: titleW, height: 18)
        titleLabel.autoresizingMask = []

        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.alignment = .right
        versionLabel.stringValue = AppInfo.full
        let verW = versionLabel.sizeThatFits(NSSize(width: 9999, height: 16)).width
        versionLabel.frame = NSRect(x: Self.contentWidth - verW, y: 3, width: verW, height: 16)
        versionLabel.autoresizingMask = []

        header.addSubview(iconView)
        header.addSubview(titleLabel)
        header.addSubview(versionLabel)
        return header
    }

    // MARK: - 概览

    private func makeOverview() -> NSView {
        let box = NSView()

        summaryLabel.font = .systemFont(ofSize: 12, weight: .medium)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.alignment = .left
        summaryLabel.frame = NSRect(x: 0, y: 10, width: Self.contentWidth, height: 16)
        summaryLabel.autoresizingMask = []

        overviewBar.frame = NSRect(x: 0, y: 0, width: Self.contentWidth, height: 4)
        overviewBar.autoresizingMask = []

        box.addSubview(summaryLabel)
        box.addSubview(overviewBar)
        return box
    }

    // MARK: - 列表

    private func makeScroll() -> NSScrollView {
        listContainer = FlippedContainer()
        listContainer.translatesAutoresizingMaskIntoConstraints = false
        listContainer.frame = NSRect(x: 0, y: 0, width: Self.contentWidth,
                                     height: listContentHeightValue)

        // 列表放进滚动视图：盘多时滚动，而不是把面板撑爆、把下面的按钮挤出屏幕
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autoresizingMask = []
        // 默认 NSClipView 原点在左下角：内容不足一屏会沉到底部、上方留大片空白。
        // 换成 flipped 的裁剪视图，内容从顶部开始排。
        scroll.contentView = FlippedClipView()
        scroll.documentView = listContainer
        scroll.verticalScroller?.controlSize = .small
        scroll.scrollerStyle = .overlay

        let heightConstraint = scroll.heightAnchor.constraint(equalToConstant: listHeight)
        heightConstraint.isActive = true
        scrollHeight = heightConstraint

        // 容器宽高写死：滚动视图据此算滚动范围和滚动条
        let contentH = listContainer.heightAnchor.constraint(equalToConstant: listContentHeightValue)
        contentH.isActive = true
        listContentHeight = contentH

        NSLayoutConstraint.activate([
            listContainer.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            listContainer.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            listContainer.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            listContainer.widthAnchor.constraint(equalToConstant: Self.contentWidth)
        ])
        return scroll
    }

    // MARK: - 底部按钮

    private func makeFooter() -> NSView {
        let footer = NSView()

        let open = AccentButton(title: "打开网盘管家", kind: .accent,
                                target: self, action: #selector(openWindow))
        let settings = AccentButton(title: "偏好设置…", kind: .neutral,
                                    target: self, action: #selector(openSettings))
        let mountAll = AccentButton(title: "挂载全部", kind: .neutral,
                                    target: self, action: #selector(mountAll))
        let unmountAll = AccentButton(title: "卸载全部", kind: .neutral,
                                      target: self, action: #selector(unmountAll))

        let half = (Self.contentWidth - 8) / 2
        let rowH: CGFloat = 26
        // 第二行在下、第一行在上
        let row2Y: CGFloat = 0
        let row1Y = rowH + 8

        open.frame = NSRect(x: 0, y: row1Y, width: half, height: rowH)
        settings.frame = NSRect(x: half + 8, y: row1Y, width: half, height: rowH)
        mountAll.frame = NSRect(x: 0, y: row2Y, width: half, height: rowH)
        unmountAll.frame = NSRect(x: half + 8, y: row2Y, width: half, height: rowH)

        for b in [open, settings, mountAll, unmountAll] {
            b.autoresizingMask = []
            footer.addSubview(b)
        }
        return footer
    }

    // MARK: - 刷新

    /// 重建列表。弹窗打开时和定时刷新时都调。
    func refresh() {
        guard isViewLoaded else { return }

        let drives = store.drives
        let mounted = drives.filter { store.volume(for: $0) != nil }.count

        summaryLabel.stringValue = drives.isEmpty
            ? "还没有网络磁盘"
            : "已挂载 \(mounted) / 共 \(drives.count) 块"
        overviewBar.progress = drives.isEmpty ? 0 : Double(mounted) / Double(drives.count)
        overviewBar.fillColor = (drives.isEmpty || mounted == drives.count)
            ? .systemGreen : .systemOrange
        overviewBar.isHidden = drives.isEmpty

        // 内容没变就别重建列表：重建会丢悬停高亮、丢滚动位置，还会让点着的按钮消失
        let signature = drives.map { "\($0.id.uuidString)|\(stateText(for: $0))|\(subtitle(for: $0))" }
            .joined(separator: "\n")
        if signature != listSignature {
            listSignature = signature
            rebuildList(drives)
        }
        applySizeIfNeeded()
    }

    private func rebuildList(_ drives: [Drive]) {
        listContainer.subviews.forEach { $0.removeFromSuperview() }

        if drives.isEmpty {
            let empty = emptyStateView()
            empty.frame = NSRect(x: 0, y: 0, width: Self.contentWidth, height: 80)
            listContainer.addSubview(empty)
        } else {
            // 容器是 flipped 的，y 从上往下递增
            var y: CGFloat = 0
            for drive in drives {
                let card = row(for: drive)
                let h = cardHeight(for: drive)
                card.frame = NSRect(x: 0, y: y, width: Self.contentWidth, height: h)
                listContainer.addSubview(card)
                y += h + Metric.rowGap
            }
        }
        listContentHeight?.constant = listContentHeightValue
    }

    /// 空状态：告诉用户下一步该干嘛，而不是干巴巴一行字
    private func emptyStateView() -> NSView {
        let box = NSView()

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "externaldrive.badge.questionmark",
                             accessibilityDescription: nil)
        icon.contentTintColor = .tertiaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 26, weight: .light)
        icon.frame = NSRect(x: (Self.contentWidth - 28) / 2, y: 40, width: 28, height: 28)
        icon.autoresizingMask = []

        let title = NSTextField(labelWithString: "还没有网络磁盘")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.alignment = .center
        title.frame = NSRect(x: 0, y: 20, width: Self.contentWidth, height: 18)
        title.autoresizingMask = []

        let hint = NSTextField(labelWithString: "点下方「打开网盘管家」添加")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        hint.frame = NSRect(x: 0, y: 2, width: Self.contentWidth, height: 15)
        hint.autoresizingMask = []

        box.addSubview(icon)
        box.addSubview(title)
        box.addSubview(hint)
        return box
    }

    /// 磁盘数量变了，面板高度得跟着变。
    /// NSPopover 的 contentSize 是创建时定死的，不主动改的话：新加的盘会被塞进
    /// 一条只有一行高的滚动区里，看着像「加了盘但没显示出来」。
    private func applySizeIfNeeded() {
        let h = preferredHeight
        guard abs(h - lastHeight) > 0.5 else { return }
        lastHeight = h
        // 高度变了：先把所有区块按新高度重排（否则顶部会被裁掉），
        // 再让容器本身贴合新高度，最后通知外层改 NSPopover.contentSize。
        layoutContent(height: h)
        view.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: h)
        onResize?(NSSize(width: Self.panelWidth, height: h))
    }

    // MARK: - 单块磁盘的卡片

    private func row(for drive: Drive) -> NSView {
        let isMounted = store.volume(for: drive) != nil
        let tint: NSColor = isMounted ? .controlAccentColor : .systemGray

        let cardH = cardHeight(for: drive)
        let card = DriveCard()
        card.frame = NSRect(x: 0, y: 0, width: Self.contentWidth, height: cardH)

        // ── 左：协议图标（圆角底 + 彩色符号） ──
        let iconBox = NSView()
        iconBox.wantsLayer = true
        iconBox.layer?.cornerRadius = 7
        iconBox.layer?.backgroundColor = tint.withAlphaComponent(0.14).cgColor
        iconBox.frame = NSRect(x: Metric.cardPad,
                               y: (cardH - Metric.iconSize) / 2,
                               width: Metric.iconSize,
                               height: Metric.iconSize)
        iconBox.autoresizingMask = []

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: drive.proto.symbol, accessibilityDescription: nil)
        icon.contentTintColor = tint
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        icon.frame = NSRect(x: (Metric.iconSize - 18) / 2, y: (Metric.iconSize - 18) / 2,
                            width: 18, height: 18)
        icon.autoresizingMask = []
        iconBox.addSubview(icon)

        // ── 右：操作按钮 ──
        let action = AccentButton(title: isMounted ? "卸载" : "挂载",
                                  kind: isMounted ? .neutral : .accent,
                                  target: self, action: #selector(toggleDrive(_:)))
        action.identifier = NSUserInterfaceItemIdentifier(drive.id.uuidString)
        action.frame = NSRect(x: Self.contentWidth - Metric.cardPad - Metric.btnW,
                              y: (cardH - Metric.btnH) / 2,
                              width: Metric.btnW,
                              height: Metric.btnH)
        action.autoresizingMask = []

        // ── 中：名称 + 状态胶囊 / 副标题 / 容量条 ──
        let name = NSTextField(labelWithString: drive.name.isEmpty ? drive.share : drive.name)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.textColor = .labelColor
        name.alignment = .left
        name.lineBreakMode = .byTruncatingTail
        name.maximumNumberOfLines = 1

        let badge = BadgeView(text: stateText(for: drive), accent: badgeColor(for: drive))

        let subtitle = NSTextField(labelWithString: subtitle(for: drive))
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .left
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.maximumNumberOfLines = 1

        let textX = Metric.cardPad + Metric.iconSize + 10
        let textW = Self.contentWidth - Metric.cardPad - Metric.btnW - 10 - textX

        // 名称宽度：最多到徽章前面，留 8pt 间距
        let nameNatural = name.sizeThatFits(NSSize(width: 9999, height: 18)).width
        let nameW = max(0, min(nameNatural, textW - badge.intrinsicWidth - 8))
        name.frame = NSRect(x: textX, y: cardH - 12 - 17, width: nameW, height: 18)
        name.autoresizingMask = []

        badge.frame = NSRect(x: textX + textW - badge.intrinsicWidth,
                             y: cardH - 12 - 17 + 1,
                             width: badge.intrinsicWidth,
                             height: badge.intrinsicHeight)
        badge.autoresizingMask = []

        subtitle.frame = NSRect(x: textX, y: cardH - 12 - 17 - 2 - 15, width: textW, height: 15)
        subtitle.autoresizingMask = []

        if let cap = store.capacity(for: drive), cap.total > 0 {
            let used = cap.total - cap.free
            let b = CapacityBar()
            b.progress = Double(used) / Double(cap.total)
            b.fillColor = Fmt.percent(used: used, total: cap.total) >= 90 ? .systemRed : .controlAccentColor
            b.frame = NSRect(x: textX, y: 12, width: textW, height: 4)
            b.autoresizingMask = []
            card.addSubview(b)
        }

        card.addSubview(iconBox)
        card.addSubview(name)
        card.addSubview(badge)
        card.addSubview(subtitle)
        card.addSubview(action)
        return card
    }

    /// 状态胶囊的颜色：绿=已挂载，橙=连接中，黄=已跳过，灰=未挂载
    private func badgeColor(for drive: Drive) -> NSColor {
        if store.busy.contains(drive.id) { return .systemOrange }
        if store.volume(for: drive) != nil { return .systemGreen }
        if store.networkSkipped.contains(drive.id) { return .systemYellow }
        return .systemGray
    }

    private func stateText(for drive: Drive) -> String {
        if store.busy.contains(drive.id) { return "连接中" }
        if store.volume(for: drive) != nil { return "已挂载" }
        if store.networkSkipped.contains(drive.id) { return "已跳过" }
        return "未挂载"
    }

    private func subtitle(for drive: Drive) -> String {
        if let cap = store.capacity(for: drive) {
            let used = cap.total - cap.free
            return "\(drive.proto.title) · 已用 \(Fmt.bytes(used)) / 共 \(Fmt.bytes(cap.total))"
        }
        if !drive.allowedSSIDs.isEmpty {
            return "\(drive.proto.title) · 只在 \(drive.allowedSSIDs.joined(separator: "、")) 下挂载"
        }
        return "\(drive.proto.title) · \(drive.host)"
    }

    // MARK: - 定时刷新

    func startRefresh() {
        refresh()
        timer?.invalidate()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopRefresh() {
        timer?.invalidate()
        timer = nil
    }

    /// 把面板渲染成 PNG（自检用：NSPopover 是独立窗口，HTML 截图拍不到它）
    func renderPNG(to path: String) {
        _ = view
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: - 动作

    @objc private func toggleDrive(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let uuid = UUID(uuidString: id),
              let drive = store.drive(id: uuid) else { return }
        store.toggleMount(drive)
        refresh()
    }

    @objc private func openWindow() { onOpenWindow?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func mountAll() { onMountAll?(); refresh() }
    @objc private func unmountAll() { onUnmountAll?(); refresh() }
}

// MARK: - 自绘控件

/// 顶部对齐的裁剪视图：NSScrollView 默认的 NSClipView 原点在左下角，
/// 内容不足一屏时会沉到底部，列表上方出现大片空白。flipped 后内容从顶部排。
private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// 列表容器：坐标原点挪到左上角，卡片自上而下排，符合阅读习惯。
private final class FlippedContainer: NSView {
    override var isFlipped: Bool { true }
}

/// 一像素分隔线。用自绘而不是 NSBox：NSBox 的高度受样式影响，这里要精确 1pt。
private final class SeparatorLine: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

/// 细进度条：底槽 + 已用部分，两端都是半圆。
private final class CapacityBar: NSView {
    var progress: Double = 0 {
        didSet {
            progress = min(max(progress, 0), 1)
            needsDisplay = true
        }
    }
    var fillColor: NSColor = .controlAccentColor {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height
        let radius = h / 2
        let track = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        track.fill()

        guard progress > 0 else { return }
        let w = max(h, bounds.width * progress)
        let fill = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: h),
                                xRadius: radius, yRadius: radius)
        fillColor.setFill()
        fill.fill()
    }
}

/// 状态胶囊：小圆点 + 文字，底色是状态色的淡色版本。
private final class BadgeView: NSView {
    private let dot = DotView()
    private let label = NSTextField(labelWithString: "")

    /// 胶囊的固定高度
    static let height: CGFloat = 18

    var intrinsicWidth: CGFloat {
        let textW = label.sizeThatFits(NSSize(width: 9999, height: 14)).width
        return 7 + 6 + 4 + textW + 7
    }
    var intrinsicHeight: CGFloat { BadgeView.height }

    init(text: String, accent: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        // 注意：属性观察器（didSet）在 init 阶段不会触发，背景色必须在这里直接设
        layer?.backgroundColor = accent.withAlphaComponent(0.15).cgColor

        label.stringValue = text
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = accent
        label.alignment = .left
        dot.color = accent
        label.autoresizingMask = []
        dot.autoresizingMask = []

        addSubview(dot)
        addSubview(label)

        let textW = label.sizeThatFits(NSSize(width: 9999, height: 14)).width
        dot.frame = NSRect(x: 7, y: (BadgeView.height - 6) / 2, width: 6, height: 6)
        label.frame = NSRect(x: 17, y: (BadgeView.height - 14) / 2, width: textW, height: 14)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 状态圆点。系统没提供现成的「彩色小圆点」控件，自己画一个最省事。
private final class DotView: NSView {
    var color: NSColor = .systemGreen {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
    }
}

/// 磁盘卡片：圆角底 + 悬停高亮。系统没有现成的卡片控件，自己画一层最省事。
private final class DriveCard: NSView {
    private var hovering = false {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9)

        let fill = hovering
            ? NSColor.controlAccentColor.withAlphaComponent(0.10)
            : NSColor.labelColor.withAlphaComponent(0.045)
        fill.setFill()
        path.fill()

        NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}

/// 自绘按钮：原生 NSButton 的 bezel 不好控制颜色，自己画一个胶囊按钮。
private final class AccentButton: NSButton {

    enum Kind {
        case accent   // 强调色实心按钮
        case neutral  // 普通描边按钮
    }

    var kind: Kind = .accent {
        didSet { needsDisplay = true }
    }

    private var hovering = false {
        didSet { needsDisplay = true }
    }

    init(title: String, kind: Kind, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        self.title = title
        self.kind = kind
        self.target = target
        self.action = action
        self.font = .systemFont(ofSize: 12, weight: .medium)
        self.isBordered = false
        self.focusRingType = .none
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)

        let titleColor: NSColor
        switch kind {
        case .accent:
            let base = NSColor.controlAccentColor
            if isHighlighted {
                base.withAlphaComponent(0.70).setFill()
            } else if hovering {
                base.withAlphaComponent(0.88).setFill()
            } else {
                base.setFill()
            }
            path.fill()
            titleColor = .white
        case .neutral:
            if isHighlighted {
                NSColor.labelColor.withAlphaComponent(0.16).setFill()
            } else if hovering {
                NSColor.labelColor.withAlphaComponent(0.09).setFill()
            } else {
                NSColor.labelColor.withAlphaComponent(0.05).setFill()
            }
            path.fill()
            NSColor.separatorColor.withAlphaComponent(0.8).setStroke()
            path.lineWidth = 1
            path.stroke()
            titleColor = .labelColor
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 12),
            .foregroundColor: titleColor
        ]
        let text = NSAttributedString(string: title, attributes: attrs)
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                              y: (bounds.height - size.height) / 2))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}
