import AppKit

// MARK: - Emoji 数据

/// 最近 emoji 列表的纯数据逻辑。参照 capcap `EditWindowController` 的
/// `recentEmojiLimit` / `defaultRecentEmojiChoices` / `emojiPickerChoices` /
/// `recentEmojiChoices(from:)` / `promoteRecentEmoji`。
enum EmojiRecents {
    static let limit = 10

    static let defaultRecent = [
        "⭐️", "❤️", "👍", "👎", "🚀",
        "😀", "😂", "😍", "🔥", "✅",
    ]

    static let pickerChoices: [String] = [
        "😀", "😄", "😂", "🤣", "😍", "🤔", "😎", "🤯", "😱",
        "😤", "🥳", "🤡", "💩", "👻", "🤖", "👽", "😈",
        "🙈", "🙉", "🙊", "💪", "👏", "🙌", "🤝", "🫡",
        "⭐️", "❤️", "👍", "👎", "🚀", "✅", "❌", "⚠️", "❓",
        "🔥", "✨", "🎉", "💡", "📌", "🚩", "☝️",
    ]

    /// 从存储数组中返回去重保序的前 `limit` 个最近 emoji；
    /// 存储为空时回退到 `defaultRecent`。
    static func choices(from stored: [String]) -> [String] {
        var result: [String] = []
        for emoji in stored + defaultRecent {
            guard !emoji.isEmpty, !result.contains(emoji) else { continue }
            result.append(emoji)
            if result.count == limit { break }
        }
        return result
    }

    /// 把 `emoji` 提升到列表首位，后面跟现有可见项和默认项补齐，截断到 `limit`。
    static func promoted(_ emoji: String, from stored: [String]) -> [String] {
        var next = [emoji]
        for existing in choices(from: stored) where existing != emoji {
            next.append(existing)
        }
        for fallback in defaultRecent where !next.contains(fallback) {
            next.append(fallback)
        }
        return Array(next.prefix(limit))
    }
}

// MARK: - EmojiCell（本文件内共享的小格子）

/// 单个 emoji 格子：居中绘制 emoji 字符，选中时画强调绿环。
/// 参照 capcap `EmojiChoiceView`。
private final class EmojiCell: NSView {
    let emoji: String
    var isSelected: Bool = false { didSet { needsDisplay = true } }

    /// 点击回调（不传参，由容器视图按 index 回查）。
    var onTap: (() -> Void)?

    init(frame: NSRect, emoji: String, fontSize: CGFloat = 23) {
        self.emoji = emoji
        self.fontSize = fontSize
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private let fontSize: CGFloat

    override func mouseDown(with event: NSEvent) {
        onTap?()
    }

    override func draw(_ dirtyRect: NSRect) {
        // 选中绿环
        if isSelected {
            let inset: CGFloat = 1
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset),
                                    xRadius: 4, yRadius: 4)
            EditorHUD.accentGreen.setStroke()
            ring.lineWidth = 2
            ring.stroke()
        }

        // emoji 字符居中
        let attr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
        ]
        let size = (emoji as NSString).size(withAttributes: attr)
        let origin = NSPoint(x: bounds.midX - size.width / 2,
                             y: bounds.midY - size.height / 2)
        (emoji as NSString).draw(at: origin, withAttributes: attr)
    }
}

// MARK: - EmojiSubToolbar

/// 最近 emoji 子工具栏：横向排列最近 emoji + 分隔线 + "更多"按钮。
/// 参照 capcap `EmojiSubToolbar`（L3388-3512）。
final class EmojiSubToolbar: NSView {

    // MARK: 回调

    var onEmojiSelected: ((String) -> Void)?
    var onMoreRequested: ((NSView) -> Void)?

    // MARK: 可读写属性

    var emojis: [String] = [] {
        didSet { rebuildEmojiViews() }
    }

    var selectedEmoji: String? {
        didSet { updateSelection() }
    }

    // MARK: 布局常量（参照 capcap）

    static let preferredVisibleWidth: CGFloat = {
        let cells = 10 * itemSize + 9 * itemGap
        return 2 * horizontalPad + cells + moreSeparatorGap + separatorWidth + emojiSeparatorGap + moreButtonSize
    }()
    static let minimumVisibleWidth: CGFloat = preferredVisibleWidth

    fileprivate static let itemSize: CGFloat = 30
    fileprivate static let itemGap: CGFloat = 4
    fileprivate static let horizontalPad: CGFloat = 8
    fileprivate static let moreButtonSize: CGFloat = 30
    fileprivate static let moreSeparatorGap: CGFloat = 8
    fileprivate static let emojiSeparatorGap: CGFloat = 8
    fileprivate static let separatorWidth: CGFloat = 1

    // MARK: 内部

    private var cells: [EmojiCell] = []
    private let moreButton: NSButton

    init(frame: NSRect, emojis: [String], selectedEmoji: String?) {
        let btn = NSButton(frame: .zero)
        btn.title = "…"
        btn.isBordered = false
        btn.bezelStyle = .regularSquare
        btn.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        btn.wantsLayer = true
        self.moreButton = btn
        super.init(frame: frame)
        self.emojis = emojis
        self.selectedEmoji = selectedEmoji
        addSubview(moreButton)
        moreButton.target = self
        moreButton.action = #selector(moreTapped)
        rebuildEmojiViews()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: 布局

    override func layout() {
        super.layout()

        let midY = bounds.midY
        var x = Self.horizontalPad
        let cellSize = Self.itemSize

        for cell in cells {
            cell.frame = NSRect(x: x, y: midY - cellSize / 2, width: cellSize, height: cellSize)
            x += cellSize + Self.itemGap
        }

        // 分隔线
        x += Self.moreSeparatorGap - Self.itemGap // 补偿最后一个 gap
        let sepFrame = NSRect(x: x, y: 6, width: Self.separatorWidth, height: bounds.height - 12)

        // 更多按钮
        x += Self.separatorWidth + Self.emojiSeparatorGap
        moreButton.frame = NSRect(x: x, y: midY - Self.moreButtonSize / 2,
                                  width: Self.moreButtonSize, height: Self.moreButtonSize)

        // 分隔线视图（若已存在则复用）
        if let sep = subviews.first(where: { $0 is SeparatorView }) {
            sep.frame = sepFrame
        } else {
            let sep = SeparatorView(frame: sepFrame)
            addSubview(sep, positioned: .below, relativeTo: moreButton)
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.preferredVisibleWidth, height: 42)
    }

    // MARK: 重建

    private func rebuildEmojiViews() {
        cells.forEach { $0.removeFromSuperview() }
        cells = []

        for emoji in emojis.prefix(10) {
            let cell = EmojiCell(
                frame: NSRect(x: 0, y: 0, width: Self.itemSize, height: Self.itemSize),
                emoji: emoji,
                fontSize: 17
            )
            cell.onTap = { [weak self] in
                self?.onEmojiSelected?(emoji)
                self?.selectedEmoji = emoji
            }
            addSubview(cell)
            cells.append(cell)
        }
        updateSelection()
        needsLayout = true
    }

    private func updateSelection() {
        for cell in cells {
            cell.isSelected = cell.emoji == selectedEmoji
        }
    }

    @objc private func moreTapped() {
        onMoreRequested?(moreButton)
    }

    // MARK: 绘制 HUD 背景

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2),
                                xRadius: EditorHUD.cornerRadius,
                                yRadius: EditorHUD.cornerRadius)
        EditorHUD.toolbarBackground().setFill()
        path.fill()
    }
}

// MARK: - 分隔线视图（EmojiSubToolbar 内部使用）

private final class SeparatorView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        EditorHUD.separator().setFill()
        bounds.fill()
    }
}

// MARK: - EmojiPickerView

/// 全量 emoji 选择网格（NSPopover 承载）。
/// 参照 capcap `EmojiPickerView`（L3514-3599）。
final class EmojiPickerView: NSView {

    static let preferredSize = NSSize(width: 520, height: 226)

    var selectedEmoji: String? {
        didSet { updateSelection() }
    }

    var onEmojiSelected: ((String) -> Void)?

    // MARK: 网格常量（参照 capcap）

    private static let gridColumns = 8
    private static let gridItemSize: CGFloat = 32
    private static let gridColumnGap: CGFloat = 25
    private static let gridRowGap: CGFloat = 8
    private static let topPad: CGFloat = 16
    private static let maxItems = 40

    private let allEmojis: [String]
    private var cells: [EmojiCell] = []

    init(frame: NSRect, emojis: [String], selectedEmoji: String?) {
        self.allEmojis = Array(emojis.prefix(Self.maxItems))
        super.init(frame: frame)
        self.selectedEmoji = selectedEmoji
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func setup() {
        let item = Self.gridItemSize
        let colGap = Self.gridColumnGap
        let rowGap = Self.gridRowGap

        let totalRowW = CGFloat(Self.gridColumns) * item + CGFloat(Self.gridColumns - 1) * colGap
        let insetX = (Self.preferredSize.width - totalRowW) / 2

        for (i, emoji) in allEmojis.enumerated() {
            let col = i % Self.gridColumns
            let row = i / Self.gridColumns
            let x = insetX + CGFloat(col) * (item + colGap)
            let y = Self.topPad + CGFloat(row) * (item + rowGap)
            let cell = EmojiCell(
                frame: NSRect(x: x, y: y, width: item, height: item),
                emoji: emoji,
                fontSize: 23
            )
            cell.onTap = { [weak self] in
                self?.onEmojiSelected?(emoji)
                self?.selectedEmoji = emoji
            }
            addSubview(cell)
            cells.append(cell)
        }
        updateSelection()
    }

    private func updateSelection() {
        for cell in cells {
            cell.isSelected = cell.emoji == selectedEmoji
        }
    }
}
