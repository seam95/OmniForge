import AppKit
import CoreGraphics
import ImageIO

/// 美化预设。参照 capcap `BeautifyPreset`：
/// 渐变配色（8 个，统一 135°）+ 壁纸预设。
struct BeautifyPreset: Equatable {
    let id: String
    let displayName: String
    let startColor: NSColor
    let endColor: NSColor
    let angleDegrees: CGFloat
    let isWallpaper: Bool

    init(id: String, displayName: String, startColor: NSColor, endColor: NSColor, angleDegrees: CGFloat = 135, isWallpaper: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.startColor = startColor
        self.endColor = endColor
        self.angleDegrees = angleDegrees
        self.isWallpaper = isWallpaper
    }

    /// Equatable 只按 id（与 capcap 一致）。
    static func == (lhs: BeautifyPreset, rhs: BeautifyPreset) -> Bool {
        lhs.id == rhs.id
    }

    /// 壁纸预设。
    static let wallpaper = BeautifyPreset(id: "wallpaper", displayName: "", startColor: .clear, endColor: .clear, angleDegrees: 0, isWallpaper: true)

    /// 默认预设表（8 渐变 + 壁纸）。配色参照 capcap `BeautifyPreset.defaults`。
    static let defaults: [BeautifyPreset] = [
        BeautifyPreset(id: "peach-blue", displayName: "", startColor: hex("#FDE8EF"), endColor: hex("#C7D7F2")),
        BeautifyPreset(id: "mint-teal", displayName: "", startColor: hex("#D4F1E5"), endColor: hex("#A7D8C6")),
        BeautifyPreset(id: "peach-pink", displayName: "", startColor: hex("#FDE1D3"), endColor: hex("#F9A8A8")),
        BeautifyPreset(id: "blue-purple", displayName: "", startColor: hex("#C9D6FF"), endColor: hex("#E2B0FF")),
        BeautifyPreset(id: "warm-orange", displayName: "", startColor: hex("#FEF3C7"), endColor: hex("#FBBF85")),
        BeautifyPreset(id: "teal-pink", displayName: "", startColor: hex("#A8EDEA"), endColor: hex("#FED6E3")),
        BeautifyPreset(id: "deep-purple", displayName: "", startColor: hex("#667EEA"), endColor: hex("#764BA2")),
        BeautifyPreset(id: "neutral-gray", displayName: "", startColor: hex("#E9ECEF"), endColor: hex("#CED4DA")),
        wallpaper,
    ]

    static func preset(forID id: String) -> BeautifyPreset? {
        defaults.first { $0.id == id }
    }

    static var defaultPreset: BeautifyPreset { defaults[0] }

    private static func hex(_ s: String) -> NSColor {
        var trimmed = s.uppercased()
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else { return .white }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

/// 美化渲染器：渐变/壁纸背景 + 圆角 + 双层阴影（ambient + key）+ padding。
///
/// 参照 capcap `BeautifyRenderer`。修正此前实现的关键 bug：
/// - 双层阴影此前连续两次 `setShadow` 是覆盖非叠加；改为 capcap 式
///   `drawShadowOnly` 两次独立 pass（ambient + key），每次用 evenOdd clip
///   把内圆角矩形排除，只在外环绘制阴影。
/// - 此前 clip 在 setShadow 之后把阴影裁掉；capcap 的 evenOdd clip 只
///   排除内部，外环阴影得以保留。
/// - 壁纸用 ImageIO 缩略图缓存 + aspect-fill（避免动态 HEIC 全量解码卡顿）。
enum BeautifyRenderer {
    // MARK: - 布局常量

    static let paddingRatio: CGFloat = 0.10
    static let paddingMin: CGFloat = 16
    static let paddingMax: CGFloat = 220
    static let innerCornerRadius: CGFloat = 12
    // ambient shadow（环绕四周的均匀辉光）。
    static let ambientShadowBlur: CGFloat = 24
    static let ambientShadowOpacity: CGFloat = 0.30
    static let ambientShadowOffset: CGSize = CGSize(width: 0, height: 0)
    // key shadow（轻微下移，模拟自然深度）。
    static let keyShadowBlur: CGFloat = 38
    static let keyShadowOpacity: CGFloat = 0.36
    static let keyShadowOffset: CGSize = CGSize(width: 0, height: -7)

    // MARK: - 几何

    static func padding(for innerSize: CGSize) -> CGFloat {
        let shortEdge = min(innerSize.width, innerSize.height)
        guard shortEdge > 0 else { return paddingMin }
        let base = shortEdge * paddingRatio
        return max(paddingMin, min(paddingMax, base))
    }

    static func outputSize(for innerSize: CGSize) -> CGSize {
        let p = padding(for: innerSize)
        return CGSize(width: innerSize.width + 2 * p, height: innerSize.height + 2 * p)
    }

    static func innerRect(for innerSize: CGSize) -> CGRect {
        let p = padding(for: innerSize)
        return CGRect(x: p, y: p, width: innerSize.width, height: innerSize.height)
    }

    static func outputSize(innerSize: CGSize, padding: CGFloat) -> CGSize {
        CGSize(width: innerSize.width + 2 * padding, height: innerSize.height + 2 * padding)
    }

    static func innerRect(innerSize: CGSize, padding: CGFloat) -> CGRect {
        CGRect(x: padding, y: padding, width: innerSize.width, height: innerSize.height)
    }

    // MARK: - 壁纸

    /// 缩略图最长边像素上限。原始桌面图常是超大动态 HEIC（>100MB），
    /// 只填 padding 边带，2560px 足够。参照 capcap。
    private static let wallpaperMaxEdge: CGFloat = 2560

    /// 按 url 缓存的缩略图。
    private static var wallpaperCache: [String: NSImage] = [:]
    private static let wallpaperCacheLock = NSLock()

    /// 异步加载桌面壁纸。completion 回主线程。参照 capcap `loadWallpaperImage`。
    static func loadWallpaperImage(for screen: NSScreen, completion: @escaping (NSImage?) -> Void) {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        if let cached = cachedWallpaper(url: url) {
            DispatchQueue.main.async { completion(cached) }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let image = autoreleasepool { downscaledWallpaper(url: url) }
            if let image { storeWallpaper(image, url: url) }
            DispatchQueue.main.async { completion(image) }
        }
    }

    /// 同步加载（缓存优先）。
    static func wallpaperImage(for screen: NSScreen) -> NSImage? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        if let cached = cachedWallpaper(url: url) { return cached }
        guard let image = downscaledWallpaper(url: url) else { return nil }
        storeWallpaper(image, url: url)
        return image
    }

    private static func cachedWallpaper(url: URL) -> NSImage? {
        wallpaperCacheLock.lock()
        defer { wallpaperCacheLock.unlock() }
        return wallpaperCache[url.path]
    }

    private static func storeWallpaper(_ image: NSImage, url: URL) {
        wallpaperCacheLock.lock()
        wallpaperCache[url.path] = image
        wallpaperCacheLock.unlock()
    }

    /// 用 ImageIO 只解码主帧并缩放到最长边 ≤ wallpaperMaxEdge，
    /// 避免动态 HEIC 全量解码卡顿。参照 capcap `downscaledWallpaper`。
    private static func downscaledWallpaper(url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return NSImage(contentsOf: url)
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: wallpaperMaxEdge,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            return NSImage(contentsOf: url)
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: - 绘制原语

    /// 渐变背景（wallpaper 预设留空，由调用方单独画壁纸）。
    static func drawBackground(in outerRect: CGRect, preset: BeautifyPreset) {
        if preset.isWallpaper { return }
        guard let gradient = NSGradient(starting: preset.startColor, ending: preset.endColor) else {
            preset.startColor.setFill()
            outerRect.fill()
            return
        }
        gradient.draw(in: outerRect, angle: preset.angleDegrees)
    }

    /// 把壁纸按 aspect-fill 居中绘制到 outerRect。参照 capcap。
    static func drawWallpaperBackground(in outerRect: CGRect, wallpaper: NSImage) {
        let wpSize = wallpaper.size
        guard wpSize.width > 0, wpSize.height > 0 else { return }
        let scaleX = outerRect.width / wpSize.width
        let scaleY = outerRect.height / wpSize.height
        let scale = max(scaleX, scaleY)
        let drawSize = CGSize(width: wpSize.width * scale, height: wpSize.height * scale)
        let drawRect = CGRect(
            x: outerRect.origin.x + (outerRect.width - drawSize.width) / 2,
            y: outerRect.origin.y + (outerRect.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        wallpaper.draw(
            in: drawRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high.rawValue]
        )
    }

    /// 双层阴影（ambient + key）。参照 capcap `drawInnerShadow`：
    /// 用 evenOdd clip 把内圆角矩形排除，阴影只画在外环。
    static func drawInnerShadow(innerRect: CGRect, cornerRadius: CGFloat, inset: CGFloat = 0, context: CGContext) {
        let shadowRect = innerRect.insetBy(dx: inset, dy: inset)
        guard shadowRect.width > 0, shadowRect.height > 0 else { return }
        let radius = max(0, cornerRadius - inset)
        let path = CGPath(
            roundedRect: shadowRect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )

        // Pass 1: ambient shadow（均匀辉光）。
        drawShadowOnly(
            path: path,
            innerRect: shadowRect,
            offset: ambientShadowOffset,
            blur: ambientShadowBlur,
            opacity: ambientShadowOpacity,
            context: context
        )
        // Pass 2: key shadow（下移，自然深度）。
        drawShadowOnly(
            path: path,
            innerRect: shadowRect,
            offset: keyShadowOffset,
            blur: keyShadowBlur,
            opacity: keyShadowOpacity,
            context: context
        )
    }

    /// 单次阴影 pass。参照 capcap `drawShadowOnly`：
    /// clip 到 [外环 clipRect, 内 path] 的 evenOdd 区域，
    /// 在内 path 上 fill 黑色触发阴影（阴影落在 clip 留下的外环）。
    private static func drawShadowOnly(
        path: CGPath,
        innerRect: CGRect,
        offset: CGSize,
        blur: CGFloat,
        opacity: CGFloat,
        context: CGContext
    ) {
        let outset = shadowOutset(blur: blur, offset: offset)
        let clipRect = innerRect.insetBy(dx: -outset, dy: -outset)

        context.saveGState()
        context.addRect(clipRect)
        context.addPath(path)
        context.clip(using: .evenOdd)
        context.setShadow(
            offset: offset,
            blur: blur,
            color: NSColor.black.withAlphaComponent(opacity).cgColor
        )
        context.addPath(path)
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
        context.restoreGState()
    }

    private static func shadowOutset(blur: CGFloat, offset: CGSize) -> CGFloat {
        blur * 3 + max(abs(offset.width), abs(offset.height)) + 2
    }

    // MARK: - 合成

    /// 内图像的像素密度（像素/点）。
    private static func pixelScale(of innerImage: NSImage) -> CGFloat {
        let pointWidth = innerImage.size.width
        guard pointWidth > 0 else { return 1 }
        let maxPixelsWide = innerImage.representations
            .map(\.pixelsWide)
            .filter { $0 > 0 }
            .max() ?? 0
        guard maxPixelsWide > 0 else { return 1 }
        return max(CGFloat(maxPixelsWide) / pointWidth, 1)
    }

    /// 用 padding 包裹内图，加背景/阴影/圆角。参照 capcap `render`。
    static func render(innerImage: NSImage, preset: BeautifyPreset, padding: CGFloat? = nil, wallpaperImage: NSImage? = nil, shadowEnabled: Bool = true) -> NSImage {
        let innerSize = innerImage.size
        guard innerSize.width > 0, innerSize.height > 0 else { return innerImage }

        let p = padding ?? Self.padding(for: innerSize)
        let outer = outputSize(innerSize: innerSize, padding: p)
        let outerRect = CGRect(origin: .zero, size: outer)
        let inner = innerRect(innerSize: innerSize, padding: p)

        // 保留 backing scale：按内图像素密度建位图。
        let innerPixelScale = pixelScale(of: innerImage)
        let pixelsWide = Int((outer.width * innerPixelScale).rounded())
        let pixelsHigh = Int((outer.height * innerPixelScale).rounded())

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        ) else {
            return innerImage
        }
        rep.size = outer

        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            return innerImage
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high

        let cg = ctx.cgContext

        // 1. 背景。
        if preset.isWallpaper, let wp = wallpaperImage {
            drawWallpaperBackground(in: outerRect, wallpaper: wp)
        } else {
            drawBackground(in: outerRect, preset: preset)
        }

        // 2. 内圆角矩形下方的柔和阴影。
        if shadowEnabled {
            drawInnerShadow(innerRect: inner, cornerRadius: innerCornerRadius, context: cg)
        }

        // 3. 圆角裁剪后绘制内图。
        cg.saveGState()
        let clipPath = CGPath(
            roundedRect: inner,
            cornerWidth: innerCornerRadius,
            cornerHeight: innerCornerRadius,
            transform: nil
        )
        cg.addPath(clipPath)
        cg.clip()
        innerImage.draw(
            in: inner,
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: nil
        )
        cg.restoreGState()

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: outer)
        image.addRepresentation(rep)
        return image
    }
}
