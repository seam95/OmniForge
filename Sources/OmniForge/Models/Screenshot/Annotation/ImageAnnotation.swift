import AppKit
import Foundation

/// 图片插入标注。绘制参照 capcap `ImageAnnotation`：高质量插值 + 保留 backing。
struct ImageAnnotation: Annotation, Equatable {
    let uuid: UUID
    var image: NSImage
    var rect: NSRect
    var rotation: CGFloat
    let supportsRotation: Bool = true

    init(uuid: UUID = UUID(), image: NSImage, rect: NSRect, rotation: CGFloat = 0) {
        self.uuid = uuid
        self.image = image
        self.rect = rect
        self.rotation = rotation
    }

    static func == (lhs: ImageAnnotation, rhs: ImageAnnotation) -> Bool {
        lhs.uuid == rhs.uuid && lhs.rect == rhs.rect && lhs.rotation == rhs.rotation
            && lhs.image === rhs.image
    }

    func draw(in context: CGContext, bounds: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: rect,
            from: NSRect(origin: .zero, size: image.size),
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high.rawValue]
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    func containsPoint(_ point: NSPoint) -> Bool {
        let p = unrotate(point)
        return rect.insetBy(dx: -8, dy: -8).contains(p)
    }

    func translated(by delta: NSPoint) -> Annotation {
        ImageAnnotation(uuid: uuid, image: image, rect: rect.offsetBy(dx: delta.x, dy: delta.y), rotation: rotation)
    }

    var boundingRect: NSRect { rect }

    func withRotation(_ rotation: CGFloat) -> Annotation { ImageAnnotation(uuid: uuid, image: image, rect: rect, rotation: rotation) }
    func withColor(_ color: NSColor) -> Annotation { self }
    func withLineWidth(_ lineWidth: CGFloat) -> Annotation { self }

    /// 调整模式：替换矩形。
    func withRect(_ rect: NSRect) -> ImageAnnotation {
        ImageAnnotation(uuid: uuid, image: image, rect: rect, rotation: rotation)
    }
}

/// Emoji 标注。绘制参照 capcap `EmojiAnnotation`：经 EmojiGlyphRenderer 缓存渲染。
struct EmojiAnnotation: Annotation, Equatable {
    let uuid: UUID
    var emoji: String
    var rect: NSRect
    var rotation: CGFloat
    let supportsRotation: Bool = true

    init(uuid: UUID = UUID(), emoji: String, rect: NSRect, rotation: CGFloat = 0) {
        self.uuid = uuid
        self.emoji = emoji
        self.rect = rect
        self.rotation = rotation
    }

    func draw(in context: CGContext, bounds: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .high
        EmojiGlyphRenderer.image(for: emoji).draw(
            in: rect,
            from: NSRect(origin: .zero, size: EmojiGlyphRenderer.imageSize),
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high.rawValue]
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    func containsPoint(_ point: NSPoint) -> Bool {
        let p = unrotate(point)
        return rect.insetBy(dx: -8, dy: -8).contains(p)
    }

    func translated(by delta: NSPoint) -> Annotation {
        EmojiAnnotation(uuid: uuid, emoji: emoji, rect: rect.offsetBy(dx: delta.x, dy: delta.y), rotation: rotation)
    }

    var boundingRect: NSRect { rect }

    func withRotation(_ rotation: CGFloat) -> Annotation { EmojiAnnotation(uuid: uuid, emoji: emoji, rect: rect, rotation: rotation) }
    func withColor(_ color: NSColor) -> Annotation { self }
    func withLineWidth(_ lineWidth: CGFloat) -> Annotation { self }

    /// 调整模式：替换矩形。
    func withRect(_ rect: NSRect) -> EmojiAnnotation {
        EmojiAnnotation(uuid: uuid, emoji: emoji, rect: rect, rotation: rotation)
    }
}

/// Emoji 字形渲染缓存。参照 capcap `EmojiGlyphRenderer`：
/// 把 emoji 预渲染成 128×128 位图并缓存，避免每次重绘重新布局字形。
private enum EmojiGlyphRenderer {
    static let imageSize = NSSize(width: 128, height: 128)
    private static var cache: [String: NSImage] = [:]

    static func image(for emoji: String) -> NSImage {
        if let cached = cache[emoji] { return cached }

        let image = NSImage(size: imageSize, flipped: false) { rect in
            let font = NSFont.systemFont(ofSize: 96)
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            let measured = (emoji as NSString).size(withAttributes: attributes)
            let origin = NSPoint(
                x: rect.midX - measured.width / 2,
                y: rect.midY - measured.height / 2
            )
            (emoji as NSString).draw(at: origin, withAttributes: attributes)
            return true
        }
        cache[emoji] = image
        return image
    }
}
