import Foundation

/// 桌面便签颜色语义；rawValue 为持久化稳定标识，只能新增不能重命名。
enum StickyNoteColor: String, Codable, CaseIterable {
    case yellow
    case mint
    case blue
    case pink
}

/// 桌面便签值类型。`hidden` 与 `completed` 独立（对齐参考应用数据语义）：
/// 「显示所有便签」等恢复规则只看 `completed`。
/// `collapsed` = 正文收起为工具栏条（窗口仍可见可拖），与 `hidden`（整窗隐藏）互不影响；
/// `frame` 恒为展开态尺寸，折叠条的窗口 frame 由展示层换算、不落库。
struct StickyNote: Identifiable, Codable, Equatable {
    /// 正文字号可选档位（升序）；步进式调节，防连点失控、UI 可预置禁用态。
    static let fontSizeSteps: [Double] = [11, 13, 15, 17, 20, 24]
    /// 正文字号默认档（档位表中的标准正文大小）。
    static let defaultFontSize: Double = 13

    let id: UUID
    var content: String
    var color: StickyNoteColor
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var pinned: Bool
    var hidden: Bool
    var completed: Bool
    var collapsed: Bool
    /// 正文字号（pt）；旧库迁移缺列时由存储层补默认档。
    var fontSize: Double
    /// 提醒时刻；nil = 未设置。
    var reminderAt: Date?
    /// 提醒已触发时刻（防重）；nil = 未触发。
    var reminderFiredAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        content: String = "",
        color: StickyNoteColor = .yellow,
        x: Double = 0,
        y: Double = 0,
        width: Double = 0,
        height: Double = 0,
        pinned: Bool = false,
        hidden: Bool = false,
        completed: Bool = false,
        collapsed: Bool = false,
        fontSize: Double = StickyNote.defaultFontSize,
        reminderAt: Date? = nil,
        reminderFiredAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.content = content
        self.color = color
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.pinned = pinned
        self.hidden = hidden
        self.completed = completed
        self.collapsed = collapsed
        self.fontSize = fontSize
        self.reminderAt = reminderAt
        self.reminderFiredAt = reminderFiredAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 提醒已到：设置过提醒且已触发。
    var isReminderFired: Bool {
        reminderAt != nil && reminderFiredAt != nil
    }

    /// 内容为空白（去除首尾空白后为空）：典型为快捷键误新建、未写过内容的便签，
    /// 没有归档价值，完成 / 隐藏 / 重启路径直接物理回收。
    var isBlank: Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 字号档位步进；返回 nil 表示已在目标方向边界（UI 据此禁用按钮）。
    /// 当前值不在档位内（旧数据异常值）时先就近对齐：
    /// 落在档位间隙 → 升到上沿档、降到下沿档；超出两端 → 收敛回端点档。
    func nextFontSize(larger: Bool) -> Double? {
        let steps = Self.fontSizeSteps
        // upperIndex：第一个 ≥ 当前值的档位索引；count = 当前值超过最大档
        let upperIndex = steps.firstIndex(where: { $0 >= fontSize }) ?? steps.count
        let target: Int
        if upperIndex < steps.count && steps[upperIndex] == fontSize {
            target = upperIndex + (larger ? 1 : -1)
        } else {
            target = larger ? upperIndex : upperIndex - 1
        }
        guard steps.indices.contains(target) else { return nil }
        return steps[target]
    }

    /// 窗口 frame（AppKit 全局坐标）；DB 四列的便捷视图。
    var frame: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set {
            x = newValue.minX
            y = newValue.minY
            width = newValue.width
            height = newValue.height
        }
    }

    /// 管理页摘要：首行去空白；空内容返回空串（占位由展示层处理）。
    var summary: String {
        let first = content.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return first.trimmingCharacters(in: .whitespaces).isEmpty ? "" : first
    }
}
