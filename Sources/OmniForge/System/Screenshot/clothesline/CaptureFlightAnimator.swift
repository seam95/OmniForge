// Sources/OmniForge/System/Screenshot/clothesline/CaptureFlightAnimator.swift
import AppKit
import QuartzCore

/// 捕获从截取处起飞飞向绳位；丢弃则整屏掉落。
/// 临时透明全屏窗 + CALayer 逐帧（120Hz Timer），结束即拆窗。
/// 途中渐长玻璃相框与衣夹，落地真卡淡入接管、动画卡淡出。
@MainActor
final class CaptureFlightAnimator: CaptureFlightAnimating {
    static let flyDuration: CFTimeInterval = 0.65
    static let fallDuration: CFTimeInterval = 0.55
    private static let arc: CGFloat = 30

    private let window: NSPanel
    private let container = CALayer()
    private let glass = CALayer()
    private let edge = CAGradientLayer()
    private let edgeMask = CAShapeLayer()
    private let photo = CALayer()
    private let clip = CAGradientLayer()

    private let from: CGRect
    private let to: CGRect
    private let tilt: CGFloat
    private var falling = false
    private var duration: CFTimeInterval = CaptureFlightAnimator.flyDuration
    private var start: CFTimeInterval = 0
    private var timer: Timer?
    private var completion: () -> Void = {}
    private static var current: [CaptureFlightAnimator] = []

    // 协议要求实例方法（Coordinator 经注入实例调用）；每次调用新建一次飞行动画实例。
    func fly(image: CGImage, from: CGRect, to: CGRect, tilt: CGFloat, on screen: NSScreen,
             completion: @escaping () -> Void) {
        let flight = CaptureFlightAnimator(image: image, from: from, to: to, tilt: tilt, screen: screen)
        Self.current.append(flight)
        flight.completion = { [weak flight] in
            completion()
            Self.current.removeAll { $0 === flight }
        }
        flight.run()
    }

    func fall(image: CGImage, card: CGRect, tilt: CGFloat, on screen: NSScreen) {
        let flight = CaptureFlightAnimator(image: image, from: card, to: card, tilt: tilt, screen: screen)
        flight.falling = true
        flight.duration = Self.fallDuration
        Self.current.append(flight)
        flight.completion = { [weak flight] in Self.current.removeAll { $0 === flight } }
        flight.run()
    }

    private init(image: CGImage, from: CGRect, to: CGRect, tilt: CGFloat, screen: NSScreen) {
        self.from = from
        self.to = to
        self.tilt = tilt
        window = NSPanel(contentRect: screen.frame,
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.animationBehavior = .none   // macOS 26 建窗动画红线

        let host = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        host.wantsLayer = true
        window.contentView = host
        let scale = screen.backingScaleFactor

        container.anchorPoint = CGPoint(x: 0.5, y: 1)   // 卡顶中心
        container.shadowColor = NSColor.black.cgColor
        container.shadowOpacity = 0.24
        container.shadowRadius = 10
        container.shadowOffset = CGSize(width: 0, height: -5)

        glass.backgroundColor = NSColor(white: 0.97, alpha: 0.72).cgColor
        edge.colors = [NSColor(white: 1, alpha: 0.9).cgColor, NSColor(white: 1, alpha: 0.25).cgColor]
        edge.startPoint = CGPoint(x: 0.5, y: 1); edge.endPoint = CGPoint(x: 0.5, y: 0)
        edgeMask.fillColor = nil
        edgeMask.strokeColor = NSColor.black.cgColor
        edgeMask.lineWidth = 1.5
        edge.mask = edgeMask

        photo.contents = image
        photo.contentsGravity = .resizeAspectFill
        photo.masksToBounds = true
        photo.contentsScale = scale

        clip.colors = [NSColor(white: 0.70, alpha: 1).cgColor, NSColor(white: 0.93, alpha: 1).cgColor,
                       NSColor(white: 0.82, alpha: 1).cgColor, NSColor(white: 0.62, alpha: 1).cgColor]
        clip.locations = [0, 0.35, 0.65, 1]
        clip.startPoint = CGPoint(x: 0, y: 0.5); clip.endPoint = CGPoint(x: 1, y: 0.5)
        clip.cornerRadius = 3.5
        clip.borderColor = NSColor(white: 1, alpha: 0.7).cgColor
        clip.borderWidth = 0.6

        for layer in [container, glass, edge, photo, clip] as [CALayer] { layer.contentsScale = scale }
        container.addSublayer(glass)
        container.addSublayer(photo)
        container.addSublayer(edge)
        container.addSublayer(clip)
        host.layer?.addSublayer(container)
    }

    private func run() {
        if falling { applyFall(0) } else { applyFlight(0) }
        window.orderFrontRegardless()
        start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let k = min(1.0, (CACurrentMediaTime() - start) / duration)
        if falling { applyFall(k) } else { applyFlight(k) }
        guard k >= 1 else { return }
        timer?.invalidate()
        timer = nil
        completion()
        if falling {
            window.orderOut(nil)
            return
        }
        // 真卡已在其下淡入；动画卡盖着淡出。
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            window.animator().alphaValue = 0
        }, completionHandler: { [window] in
            MainActor.assumeIsolated { window.orderOut(nil) }
        })
    }

    private func applyFlight(_ rawK: Double) {
        let state = CaptureFlightMath.flightState(k: rawK, from: from, to: to, tilt: tilt,
                                                  arc: Self.arc)
        let origin = window.frame.origin
        let inset = 4 * CGFloat(state.chrome)
        let radius = state.bounds.width * 0.1   // 0 → 16 比例近似，落地对齐视图 16pt
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.bounds = state.bounds
        container.position = CGPoint(x: state.position.x - origin.x, y: state.position.y - origin.y)
        // SwiftUI 顺时针为正，CA 相反。
        container.setAffineTransform(CGAffineTransform(rotationAngle: -state.angle * .pi / 180))
        container.shadowPath = CGPath(roundedRect: state.bounds, cornerWidth: radius,
                                      cornerHeight: radius, transform: nil)
        glass.frame = state.bounds
        glass.cornerRadius = radius
        glass.opacity = state.chrome
        edge.frame = state.bounds
        edgeMask.path = CGPath(roundedRect: state.bounds.insetBy(dx: 0.75, dy: 0.75),
                               cornerWidth: max(0, radius - 0.75), cornerHeight: max(0, radius - 0.75),
                               transform: nil)
        edge.opacity = state.chrome
        photo.frame = state.bounds.insetBy(dx: inset, dy: inset)
        photo.cornerRadius = max(0, radius - inset)
        clip.frame = CGRect(x: state.bounds.width / 2 - 4.5, y: state.bounds.height - 12,
                            width: 9, height: 26)
        clip.opacity = state.chrome
        CATransaction.commit()
    }

    private func applyFall(_ rawK: Double) {
        let state = CaptureFlightMath.fallState(k: rawK, tilt: tilt)
        let origin = window.frame.origin
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.position = CGPoint(x: to.midX - origin.x, y: to.maxY - origin.y - state.offset)
        container.setAffineTransform(
            CGAffineTransform(rotationAngle: -(tilt + state.angle) * .pi / 180))
        container.opacity = state.opacity
        CATransaction.commit()
    }
}
