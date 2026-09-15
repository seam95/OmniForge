import Foundation

/// 宠物资产包：一份图集 + 动画清单。
/// 图集为均匀网格切片（行优先编号），网格尺寸可配置，
/// 天然覆盖社区 8×9 图集约定，为二期导入外部资产留门。
struct PetSpriteAsset: Equatable {
    /// 资产标识（目录名）。
    let id: String
    /// 展示名称。
    let displayName: String
    /// 图集文件名（同目录）。
    let atlasFileName: String
    /// 图集网格描述。
    let grid: Grid
    /// 动画定义，按声明顺序。
    let animations: [Animation]
    /// 看向帧映射：固定 16 个方向槽位（顺时针，正上为 0），每格为图集帧号或缺失。
    /// 长度恒为 16（无看向能力时全 nil），不压缩缺失方向——渲染层按槽位取帧，缺帧回退底层动画。
    var lookFrames: [Int?] = Array(repeating: nil, count: PetLookOverlay.directionCount)

    /// 图集网格：列数 / 行数 / 单元格像素尺寸。
    struct Grid: Equatable {
        let columns: Int
        let rows: Int
        let cellWidth: Int
        let cellHeight: Int

        /// 单元格总数。
        var cellCount: Int { columns * rows }

        /// 图集总像素尺寸。
        var atlasSize: CGSize {
            CGSize(width: columns * cellWidth, height: rows * cellHeight)
        }
    }

    /// 一段动画：由图集单元格序号区间驱动。
    struct Animation: Equatable {
        /// 动画标识（idle / walk / fall / petted 等）。
        let id: String
        /// 帧序列（图集单元格序号，行优先）。
        let frames: [Int]
        /// 每秒帧数。
        let fps: Double
        /// 是否循环播放。
        let loops: Bool
        /// 该动画水平方向播放时是否镜像（行走素材只画一个朝向）。
        let mirrorX: Bool

        /// 单帧时长（秒）。
        var frameDuration: TimeInterval { fps > 0 ? 1.0 / fps : 0.25 }
    }

    /// 按标识取动画。
    func animation(id: String) -> Animation? {
        animations.first { $0.id == id }
    }

    /// 指定方向槽位（0…15）的看向帧号；越界或缺帧返回 nil。
    func lookFrame(direction: Int) -> Int? {
        guard direction >= 0, direction < lookFrames.count else { return nil }
        return lookFrames[direction]
    }

    /// 是否存在任一有效看向帧（全部为 nil 时看向覆盖整体不启用）。
    var hasLookFrames: Bool { lookFrames.contains { $0 != nil } }

    /// 单元格宽高比（宽 / 高）。桌宠窗口按此比例呈现，避免拉伸变形。
    var aspectRatio: CGFloat {
        guard grid.cellHeight > 0 else { return 1 }
        return CGFloat(grid.cellWidth) / CGFloat(grid.cellHeight)
    }
}

/// 行为状态与动画标识的对应关系（状态机不依赖资产，此处做映射）。
/// 内置资产使用 `walk` + `mirrorX` 表达左右；社区资产（petdex）左右各一行，用 `walkLeft`/`walkRight`。
enum PetAnimationID {
    static let idle = "idle"
    /// 单朝向行走（配合 `mirrorX` 翻转实现左右）。
    static let walk = "walk"
    static let walkRight = "walk-right"
    static let walkLeft = "walk-left"
    static let fall = "fall"
    static let petted = "petted"
    /// 拖拽悬空姿态（petdex 的 jumping 行）。
    static let drag = "drag"
    /// 看向：frames 须恰好 16 项、按方向槽位顺序解释（不限于图集第 9/10 行）。
    /// 不参与普通动画播放，也不作为缺 idle 时的兜底。
    static let look = "look"
    // 以下为社区资产保留、一期不驱动（二期接 Agent 状态反应时启用）。
    static let failed = "failed"
    static let waiting = "waiting"
    static let review = "review"
}

// MARK: - 解码

/// `pet.json` 解码失败原因。
enum PetAssetError: Error, Equatable, LocalizedError {
    case fileNotFound(String)
    case invalidJSON(String)
    case missingField(String)
    case emptyAnimations
    case emptyFrames(animation: String)
    case invalidFrameRange(animation: String, raw: String)
    case frameOutOfBounds(animation: String, index: Int, cellCount: Int)
    /// 网格乘法溢出或超出图集规模预算（格数/像素边长）。
    case gridTooLarge(columns: Int, rows: Int)
    /// 帧总数（含重复区间展开）超出预算。
    case tooManyFrames(animation: String, count: Int, budget: Int)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let name):
            return "找不到宠物资产文件：\(name)"
        case .invalidJSON(let detail):
            return "宠物资产 JSON 解析失败：\(detail)"
        case .missingField(let field):
            return "宠物资产缺少字段：\(field)"
        case .emptyAnimations:
            return "宠物资产未定义任何动画"
        case .emptyFrames(let animation):
            return "动画「\(animation)」没有任何帧"
        case .invalidFrameRange(let animation, let raw):
            return "动画「\(animation)」帧区间非法：\(raw)"
        case .frameOutOfBounds(let animation, let index, let cellCount):
            return "动画「\(animation)」帧序号 \(index) 超出图集范围（共 \(cellCount) 格）"
        case .gridTooLarge(let columns, let rows):
            return "宠物图集网格 \(columns)×\(rows) 溢出或超出规模预算"
        case .tooManyFrames(let animation, let count, let budget):
            return "动画「\(animation)」帧总数 \(count) 超出预算 \(budget)"
        }
    }
}

extension PetSpriteAsset {
    /// 图集规模预算：格数上限（真实图集 8×11=88，宽松覆盖任意第三方素材）。
    static let maxAtlasCellCount = 1_000_000
    /// 图集单边像素上限。
    static let maxAtlasPixelSide = 32_768
    /// 全部动画（含 look 展开）帧总数预算：限制解码期展开的内存规模。
    static let maxTotalFrameCount = 16_384

    /// 从 JSON 数据解码。
    /// 帧区间写法支持 `"3"`（单帧）与 `"0-3"`（闭区间）；图集序号越界即报错。
    static func decode(from data: Data) throws -> PetSpriteAsset {
        let raw: RawAsset
        do {
            raw = try JSONDecoder().decode(RawAsset.self, from: data)
        } catch {
            throw PetAssetError.invalidJSON(error.localizedDescription)
        }
        return try make(from: raw)
    }

    /// 从资产目录加载（目录内须含 `pet.json` 与图集）。
    static func load(from directory: URL) throws -> PetSpriteAsset {
        let manifest = directory.appendingPathComponent("pet.json")
        guard let data = try? Data(contentsOf: manifest) else {
            throw PetAssetError.fileNotFound(manifest.lastPathComponent)
        }
        return try decode(from: data)
    }

    private static func make(from raw: RawAsset) throws -> PetSpriteAsset {
        guard let grid = raw.grid else { throw PetAssetError.missingField("grid") }
        guard let animations = raw.animations, !animations.isEmpty else {
            throw PetAssetError.emptyAnimations
        }

        let resolvedGrid = Grid(
            columns: grid.columns,
            rows: grid.rows,
            cellWidth: grid.cellSize.first ?? 0,
            cellHeight: grid.cellSize.count > 1 ? grid.cellSize[1] : (grid.cellSize.first ?? 0)
        )
        guard resolvedGrid.columns > 0, resolvedGrid.rows > 0,
              resolvedGrid.cellWidth > 0, resolvedGrid.cellHeight > 0 else {
            throw PetAssetError.missingField("grid.columns/rows/cellSize")
        }

        // 网格算术预算：乘法溢出与规模上限都在任何区间展开之前完成，
        // 损坏资产（如 Int.max 网格）在此快速失败，不会升级为 trap 或内存耗尽。
        let (cellCount, cellOverflow) = resolvedGrid.columns.multipliedReportingOverflow(by: resolvedGrid.rows)
        let (atlasWidth, widthOverflow) = resolvedGrid.columns.multipliedReportingOverflow(by: resolvedGrid.cellWidth)
        let (atlasHeight, heightOverflow) = resolvedGrid.rows.multipliedReportingOverflow(by: resolvedGrid.cellHeight)
        guard !cellOverflow, !widthOverflow, !heightOverflow,
              cellCount <= maxAtlasCellCount,
              atlasWidth <= maxAtlasPixelSide, atlasHeight <= maxAtlasPixelSide else {
            throw PetAssetError.gridTooLarge(columns: resolvedGrid.columns, rows: resolvedGrid.rows)
        }

        // 帧数预算池：look 与普通动画共用（展开前按段统计扣减，不先展开再验证）。
        var frameBudget = maxTotalFrameCount

        // look 声明单独解析：数量必须恰好 16 且帧号全部合法，否则忽略整组
        // 看向能力（不影响其他动画加载）。它不进 animations，避免参与通用兜底。
        var lookFrames: [Int?]?
        if let lookRaw = animations.first(where: { $0.id == PetAnimationID.look }),
           let frames = lookRaw.frames,
           let spans = try? parseFrameSpans(frames, animation: lookRaw.id),
           let indices = try? expandSpans(spans, animation: lookRaw.id, cellCount: cellCount, budget: &frameBudget),
           indices.count == PetLookOverlay.directionCount {
            lookFrames = indices
        }

        let resolvedAnimations = try animations
            .filter { $0.id != PetAnimationID.look }
            .map { animation -> Animation in
            guard let frames = animation.frames else {
                throw PetAssetError.missingField("animations[].frames")
            }
            let spans = try parseFrameSpans(frames, animation: animation.id)
            let indices = try expandSpans(
                spans,
                animation: animation.id,
                cellCount: cellCount,
                budget: &frameBudget
            )
            guard !indices.isEmpty else {
                throw PetAssetError.emptyFrames(animation: animation.id)
            }
            return Animation(
                id: animation.id,
                frames: indices,
                fps: animation.fps ?? 8,
                loops: animation.loop ?? true,
                mirrorX: animation.mirrorX ?? false
            )
        }

        return PetSpriteAsset(
            id: raw.id ?? raw.name,
            displayName: raw.displayName ?? raw.name,
            atlasFileName: raw.atlas,
            grid: resolvedGrid,
            animations: resolvedAnimations,
            lookFrames: lookFrames ?? Array(repeating: nil, count: PetLookOverlay.directionCount)
        )
    }

    /// 帧区间段（未展开）：单帧或闭区间。词法解析阶段不展开，先做预算与范围校验。
    private enum FrameSpan {
        case single(Int)
        case range(ClosedRange<Int>)
    }

    /// 解析帧区间字符串：`"3"` 或 `"0-3"`（闭区间，支持多段以逗号分隔），只产出段，不展开。
    private static func parseFrameSpans(_ raw: String, animation: String) throws -> [FrameSpan] {
        var spans: [FrameSpan] = []
        for segment in raw.split(separator: ",") {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "-", omittingEmptySubsequences: false)
            switch parts.count {
            case 1:
                guard let value = Int(parts[0]) else {
                    throw PetAssetError.invalidFrameRange(animation: animation, raw: trimmed)
                }
                spans.append(.single(value))
            case 2:
                guard let lower = Int(parts[0]), let upper = Int(parts[1]), lower <= upper else {
                    throw PetAssetError.invalidFrameRange(animation: animation, raw: trimmed)
                }
                spans.append(.range(lower...upper))
            default:
                throw PetAssetError.invalidFrameRange(animation: animation, raw: trimmed)
            }
        }
        return spans
    }

    /// 展开前的双重校验：帧号范围 + 帧总数预算（重复区间同样计入），通过后才生成帧序列。
    private static func expandSpans(
        _ spans: [FrameSpan],
        animation: String,
        cellCount: Int,
        budget: inout Int
    ) throws -> [Int] {
        var totalCount = 0
        for span in spans {
            let spanCount: Int
            switch span {
            case .single: spanCount = 1
            case .range(let range):
                // 区间长度 = upper-lower+1；差值已达 Int.max 时真实长度无法表示，
                // 用 Int.max 充当「至少 Int.max」（预算判断不受影响），避免 ClosedRange.count 的溢出 trap。
                let width = range.upperBound - range.lowerBound
                spanCount = width == Int.max ? Int.max : width + 1
            }
            let (summed, overflow) = totalCount.addingReportingOverflow(spanCount)
            guard !overflow, summed <= budget else {
                throw PetAssetError.tooManyFrames(animation: animation, count: summed, budget: budget)
            }
            totalCount = summed
        }

        var frames: [Int] = []
        frames.reserveCapacity(totalCount)
        for span in spans {
            switch span {
            case .single(let index):
                guard index >= 0, index < cellCount else {
                    throw PetAssetError.frameOutOfBounds(animation: animation, index: index, cellCount: cellCount)
                }
                frames.append(index)
            case .range(let range):
                guard range.lowerBound >= 0, range.upperBound < cellCount else {
                    throw PetAssetError.frameOutOfBounds(
                        animation: animation,
                        index: range.upperBound,
                        cellCount: cellCount
                    )
                }
                frames.append(contentsOf: range)
            }
        }
        budget -= totalCount
        return frames
    }
}

// MARK: - JSON 原始结构

private struct RawAsset: Decodable {
    let id: String?
    let name: String
    let displayName: String?
    let atlas: String
    let grid: RawGrid?
    let animations: [RawAnimation]?

    enum CodingKeys: String, CodingKey {
        case id, name, displayName, atlas, grid, animations
    }
}

private struct RawGrid: Decodable {
    let columns: Int
    let rows: Int
    /// `[宽, 高]`；只给一个值时宽高相同。
    let cellSize: [Int]
}

private struct RawAnimation: Decodable {
    let id: String
    let frames: String?
    let fps: Double?
    let loop: Bool?
    let mirrorX: Bool?
}
