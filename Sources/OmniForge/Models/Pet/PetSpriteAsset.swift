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

        let resolvedAnimations = try animations.map { animation -> Animation in
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
            animations: resolvedAnimations
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
