import AppKit
import CoreGraphics
import Foundation

/// petdex 资产适配失败原因。
enum PetdexAssetError: Error, Equatable, LocalizedError {
    case missingPetJSON
    case missingSpritesheet
    case unreadableSpritesheet
    case unsupportedAtlasSize(width: Int, height: Int)
    case noAnimationFrames
    case sourceInsideLibrary

    var errorDescription: String? {
        switch self {
        case .missingPetJSON:
            return "宠物目录缺少 pet.json"
        case .missingSpritesheet:
            return "宠物目录缺少图集文件（spritesheet.webp / .png）"
        case .unreadableSpritesheet:
            return "无法解码宠物图集"
        case .unsupportedAtlasSize(let width, let height):
            return "图集尺寸不受支持：\(width)×\(height)"
        case .noAnimationFrames:
            return "图集中没有任何可用帧"
        case .sourceInsideLibrary:
            return "不能从宠物库自身导入（请选择库外的宠物目录）"
        }
    }
}

/// petdex 社区资产适配器：把 `pet.json` + 图集转换为本应用统一的 `PetSpriteAsset`。
///
/// petdex 图集规格（源码与实测确认）：
/// - v1 为 8 列 × 9 行（1536×1872，每帧 192×208）；行序即动画状态语义。
/// - `pet.json` 极简，**不含动画定义**，动画状态由图集行号约定表达；
///   每行帧数不写在元数据里，靠逐格 alpha 扫描推断（帧自左向右连续排列）。
enum PetdexAssetAdapter {
    /// 固定 8 列。
    static let columns = 8
    /// v1 状态行数。
    static let v1StateRows = 9
    /// v2 图集物理行数（前 9 行同 v1 语义，多 2 行留给消费端，忽略）。
    static let v2StateRows = 11

    /// 行号 → 本应用动画 id（v1 九行约定）。
    /// 行 5/6/8（failed / waiting / review）一期不驱动，保留供二期接 Agent 状态反应。
    /// 行 7（running）语义与 walk 重复，不单独映射，避免 id 冲突。
    static let rowAnimationIDs: [String?] = [
        PetAnimationID.idle,       // 0 idle
        PetAnimationID.walkRight,  // 1 running-right
        PetAnimationID.walkLeft,   // 2 running-left
        PetAnimationID.petted,     // 3 waving
        PetAnimationID.drag,       // 4 jumping
        PetAnimationID.failed,     // 5 failed
        PetAnimationID.waiting,    // 6 waiting
        nil,                       // 7 running（与 walk 重复）
        PetAnimationID.review,     // 8 review
    ]

    /// 各动画的默认播放帧率（petdex 不提供 fps，按语义给默认值）。
    static func defaultFPS(for animationID: String) -> Double {
        switch animationID {
        case PetAnimationID.idle: return 4
        case PetAnimationID.walkLeft, PetAnimationID.walkRight, PetAnimationID.walk: return 8
        case PetAnimationID.petted: return 6
        default: return 6
        }
    }

    /// 从宠物目录加载并适配。
    /// 资产 `id` 取目录名，保证与 `PetAssetLocator` 的查找一致。
    static func load(from directory: URL) throws -> PetSpriteAsset {
        let manifestURL = directory.appendingPathComponent("pet.json")
        guard let manifestData = try? Data(contentsOf: manifestURL) else {
            throw PetdexAssetError.missingPetJSON
        }
        let meta = try? JSONDecoder().decode(Manifest.self, from: manifestData)

        let sheetURL = try locateSpritesheet(in: directory, declared: meta?.spritesheetPath)
        guard let image = NSImage(contentsOf: sheetURL),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw PetdexAssetError.unreadableSpritesheet
        }

        let width = cgImage.width
        let height = cgImage.height
        // 行数按图集实际尺寸判定（manifest 与 pet.json 的版本字段均不可靠，
        // 实测存在 manifest 标 v1 而图集为 8×11 的情况）。
        // v2（8×11）的前 9 行与 v1 同语义，仅多 2 行消费端自定义行，忽略即可。
        let rows: Int
        if height % v1StateRows == 0 {
            rows = v1StateRows
        } else if height % v2StateRows == 0 {
            rows = v1StateRows
        } else {
            throw PetdexAssetError.unsupportedAtlasSize(width: width, height: height)
        }
        guard width % columns == 0, width > 0, height > 0 else {
            throw PetdexAssetError.unsupportedAtlasSize(width: width, height: height)
        }
        let cellWidth = width / columns
        let cellHeight = height / Self.atlasRows(forHeight: height)

        guard let (alpha, bytesPerRow) = alphaBuffer(cgImage) else {
            throw PetdexAssetError.unreadableSpritesheet
        }

        // 逐行扫描占用格，行号 → 动画 id。
        var animations: [PetSpriteAsset.Animation] = []
        // 首个非空行：部分宠物没有 idle 行，用它兜底保证静止时有画面。
        var firstRowFrames: [Int] = []

        for row in 0..<rows {
            let frames = occupiedFrames(
                row: row,
                columns: columns,
                cellWidth: cellWidth,
                cellHeight: cellHeight,
                atlasHeight: height,
                alpha: alpha,
                bytesPerRow: bytesPerRow
            )
            guard !frames.isEmpty else { continue }
            if firstRowFrames.isEmpty { firstRowFrames = frames }

            guard let animationID = rowAnimationIDs[row] else { continue }
            animations.append(
                PetSpriteAsset.Animation(
                    id: animationID,
                    frames: frames,
                    fps: defaultFPS(for: animationID),
                    loops: animationID != PetAnimationID.petted,
                    mirrorX: false
                )
            )
        }

        guard !animations.isEmpty else {
            throw PetdexAssetError.noAnimationFrames
        }

        // 缺失 idle 动画时用首个可用行兜底。
        if animations.first(where: { $0.id == PetAnimationID.idle }) == nil, !firstRowFrames.isEmpty {
            animations.insert(
                PetSpriteAsset.Animation(
                    id: PetAnimationID.idle,
                    frames: firstRowFrames,
                    fps: defaultFPS(for: PetAnimationID.idle),
                    loops: true,
                    mirrorX: false
                ),
                at: 0
            )
        }

        return PetSpriteAsset(
            id: directory.lastPathComponent,
            displayName: meta?.displayName ?? directory.lastPathComponent,
            atlasFileName: sheetURL.lastPathComponent,
            grid: PetSpriteAsset.Grid(
                columns: columns,
                // 裁剪按图集物理行数（v2 = 11），语义行数（9）只决定扫描哪些行。
                rows: Self.atlasRows(forHeight: height),
                cellWidth: cellWidth,
                cellHeight: cellHeight
            ),
            animations: animations
        )
    }

    // MARK: - 私有

    /// 图集物理行数：高 %9==0 为 v1（9 行），否则按 %11 判为 v2（11 行）。
    private static func atlasRows(forHeight height: Int) -> Int {
        height % v1StateRows == 0 ? v1StateRows : v2StateRows
    }

    /// 定位图集：优先 pet.json 声明，其次常见文件名。
    private static func locateSpritesheet(in directory: URL, declared: String?) throws -> URL {
        let fileManager = FileManager.default
        if let declared, !declared.isEmpty {
            let candidate = directory.appendingPathComponent(declared)
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        for name in ["spritesheet.webp", "spritesheet.png"] {
            let candidate = directory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        throw PetdexAssetError.missingSpritesheet
    }

    /// 把图集解码为 RGBA 缓冲区（用于 alpha 扫描）。
    private static func alphaBuffer(_ cgImage: CGImage) -> ([UInt8], Int)? {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var success = false
        buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            success = true
        }
        return success ? (buffer, bytesPerRow) : nil
    }

    /// 扫描某一行的占用单元格，返回从左到右的帧序号（图集行优先编号）。
    /// 判定标准：单元格内 alpha > 8 的像素占比超过 1%。
    private static func occupiedFrames(
        row: Int,
        columns: Int,
        cellWidth: Int,
        cellHeight: Int,
        atlasHeight: Int,
        alpha: [UInt8],
        bytesPerRow: Int
    ) -> [Int] {
        let alphaThreshold: UInt8 = 8
        let minOpaquePixels = max(1, cellWidth * cellHeight / 100)
        var frames: [Int] = []

        for column in 0..<columns {
            var opaqueCount = 0
            let baseX = column * cellWidth
            // CGContext 原点在左下，图集行自顶向下，需翻转 y。
            let topY = row * cellHeight
            for y in 0..<cellHeight {
                let pixelY = atlasHeight - 1 - (topY + y)
                let rowStart = pixelY * bytesPerRow
                for x in 0..<cellWidth {
                    let alphaValue = alpha[rowStart + (baseX + x) * 4 + 3]
                    if alphaValue > alphaThreshold { opaqueCount += 1 }
                }
            }
            if opaqueCount >= minOpaquePixels {
                frames.append(row * columns + column)
            }
        }
        return frames
    }

    /// pet.json 结构（极简，字段均可选以容错；spriteVersionNumber 不可靠，忽略）。
    private struct Manifest: Decodable {
        let id: String?
        let displayName: String?
        let description: String?
        let spritesheetPath: String?
    }
}
