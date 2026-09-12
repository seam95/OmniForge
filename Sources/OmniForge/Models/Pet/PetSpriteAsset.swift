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
        }
    }
}

extension PetSpriteAsset {
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

        // look 声明单独解析：数量必须恰好 16 且帧号全部合法，否则忽略整组
        // 看向能力（不影响其他动画加载）。它不进 animations，避免参与通用兜底。
        var lookFrames: [Int?]?
        if let lookRaw = animations.first(where: { $0.id == PetAnimationID.look }) {
            if let frames = lookRaw.frames,
               let indices = try? parseFrames(frames, animation: lookRaw.id),
               indices.count == PetLookOverlay.directionCount,
               indices.allSatisfy({ $0 >= 0 && $0 < resolvedGrid.cellCount }) {
                lookFrames = indices
            }
        }

        let resolvedAnimations = try animations
            .filter { $0.id != PetAnimationID.look }
            .map { animation -> Animation in
            guard let frames = animation.frames else {
                throw PetAssetError.missingField("animations[].frames")
            }
            let indices = try parseFrames(frames, animation: animation.id)
            guard !indices.isEmpty else {
                throw PetAssetError.emptyFrames(animation: animation.id)
            }
            for index in indices where index < 0 || index >= resolvedGrid.cellCount {
                throw PetAssetError.frameOutOfBounds(
                    animation: animation.id,
                    index: index,
                    cellCount: resolvedGrid.cellCount
                )
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

    /// 解析帧区间字符串：`"3"` 或 `"0-3"`（闭区间，支持多段以逗号分隔）。
    private static func parseFrames(_ raw: String, animation: String) throws -> [Int] {
        var result: [Int] = []
        for segment in raw.split(separator: ",") {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "-", omittingEmptySubsequences: false)
            switch parts.count {
            case 1:
                guard let value = Int(parts[0]) else {
                    throw PetAssetError.invalidFrameRange(animation: animation, raw: trimmed)
                }
                result.append(value)
            case 2:
                guard let lower = Int(parts[0]), let upper = Int(parts[1]), lower <= upper else {
                    throw PetAssetError.invalidFrameRange(animation: animation, raw: trimmed)
                }
                result.append(contentsOf: lower...upper)
            default:
                throw PetAssetError.invalidFrameRange(animation: animation, raw: trimmed)
            }
        }
        return result
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
