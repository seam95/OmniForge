import XCTest
import SwiftUI
@testable import OmniForge

/// SVG path 解析器与真实品牌 logo 数据（2026-08-25 替换手绘近似符号）。
final class SVGPathShapeTests: XCTestCase {

    // MARK: - 基础命令解析

    func test_parse_absoluteMLCZ() {
        var parser = SVGPathParser(data: "M0 0 L10 10 Z")
        let commands = parser.parse()
        XCTAssertEqual(commands, [
            .moveTo(CGPoint(x: 0, y: 0)),
            .lineTo(CGPoint(x: 10, y: 10)),
            .closeSubpath,
        ])
    }

    func test_parse_relativeCommands() {
        var parser = SVGPathParser(data: "m 5 5 l 10 0 l 0 10")
        let commands = parser.parse()
        XCTAssertEqual(commands, [
            .moveTo(CGPoint(x: 5, y: 5)),
            .lineTo(CGPoint(x: 15, y: 5)),
            .lineTo(CGPoint(x: 15, y: 15)),
        ])
    }

    func test_parse_moveThenImplicitLines() {
        // M 后的后续坐标对按隐式 L 解析。
        var parser = SVGPathParser(data: "M 1 2 3 4 5 6")
        let commands = parser.parse()
        XCTAssertEqual(commands, [
            .moveTo(CGPoint(x: 1, y: 2)),
            .lineTo(CGPoint(x: 3, y: 4)),
            .lineTo(CGPoint(x: 5, y: 6)),
        ])
    }

    func test_parse_horizontalVerticalAndCubic() {
        var parser = SVGPathParser(data: "M 0 0 H 10 V 5 C 1 1 2 2 3 3")
        let commands = parser.parse()
        XCTAssertEqual(commands, [
            .moveTo(CGPoint(x: 0, y: 0)),
            .lineTo(CGPoint(x: 10, y: 0)),
            .lineTo(CGPoint(x: 10, y: 5)),
            .cubicTo(
                control1: CGPoint(x: 1, y: 1),
                control2: CGPoint(x: 2, y: 2),
                end: CGPoint(x: 3, y: 3)
            ),
        ])
    }

    func test_parse_implicitCubicRepeat() {
        var parser = SVGPathParser(data: "M 0 0 C 1 1 2 2 3 3 4 4 5 5 6 6")
        let commands = parser.parse()
        XCTAssertEqual(commands.count, 3)
        XCTAssertEqual(commands[2], .cubicTo(
            control1: CGPoint(x: 4, y: 4),
            control2: CGPoint(x: 5, y: 5),
            end: CGPoint(x: 6, y: 6)
        ))
    }

    func test_parse_closeResetsToSubpathStart() {
        var parser = SVGPathParser(data: "M 10 10 L 20 20 Z L 0 0")
        let commands = parser.parse()
        // close 后当前点回到子路径起点 (10,10)，后续 L 从 (10,10) 出发。
        XCTAssertEqual(commands.last, .lineTo(CGPoint(x: 0, y: 0)))
    }

    func test_parse_quadraticConvertedToCubic() {
        var parser = SVGPathParser(data: "M 0 0 Q 10 10 20 0")
        let commands = parser.parse()
        guard case let .cubicTo(c1, c2, end)? = commands.last else {
            return XCTFail("Q 应转换为三次贝塞尔")
        }
        XCTAssertEqual(end, CGPoint(x: 20, y: 0))
        // 二次贝塞尔转三次：控制点位于端点与二次控制点连线的 2/3 处。
        XCTAssertEqual(c1.x, 0 + 10 * 2 / 3, accuracy: 0.0001)
        XCTAssertEqual(c1.y, 0 + 10 * 2 / 3, accuracy: 0.0001)
        XCTAssertEqual(c2.x, 20 + (10 - 20) * 2 / 3, accuracy: 0.0001)
    }

    func test_parse_smoothCubicReflectsControlPoint() {
        var parser = SVGPathParser(data: "M 0 0 C 0 10 10 10 10 0 S 20 -10 20 0")
        let commands = parser.parse()
        guard case let .cubicTo(c1, _, end)? = commands.last else {
            return XCTFail("S 应转换为三次贝塞尔")
        }
        // 反射上一段 c2(10,10) 关于当前点 (10,0) 的镜像。
        assertPoint(c1, CGPoint(x: 10, y: -10), accuracy: 0.0001, "S 反射控制点")
        assertPoint(end, CGPoint(x: 20, y: 0), accuracy: 0.0001, "S 终点")
    }

    // MARK: - 圆弧解析

    func test_parse_arcCompactFlags() {
        // 弧段标志位可紧贴相连：`01` = largeArc=0, sweep=1。
        var parser = SVGPathParser(data: "M 0 0 A 10 10 0 01 10 10")
        let commands = parser.parse()
        guard case let .cubicTo(_, _, end)? = commands.last else {
            return XCTFail("弧段应转换为三次贝塞尔")
        }
        assertPoint(end, CGPoint(x: 10, y: 10), accuracy: 0.0001, "弧段终点")
    }

    func test_parse_arcCompactFlagsMergedWithCoordinate() {
        // `001.545` = flags(0,0) + x(1.545)，对应真实 deepseek path 的写法。
        var parser = SVGPathParser(data: "M 0 0 A 10 10 0 001.5 2")
        let commands = parser.parse()
        guard case let .cubicTo(_, _, end)? = commands.last else {
            return XCTFail("弧段应转换为三次贝塞尔")
        }
        assertPoint(end, CGPoint(x: 1.5, y: 2), accuracy: 0.0001, "紧凑标志位弧段终点")
    }

    func test_arc_geometryQuarterArc() {
        // (0,0) → (10,10)，rx=ry=10，fA=0, fS=1：四分之一圆弧，圆心 (0,10)。
        let segments = SVGPathParser.arcToBeziers(
            from: CGPoint(x: 0, y: 0),
            to: CGPoint(x: 10, y: 10),
            radiusX: 10, radiusY: 10,
            rotationDegrees: 0,
            largeArc: false, sweep: true
        )
        XCTAssertEqual(segments.count, 1)
        let (_, _, end) = segments[0]
        assertPoint(end, CGPoint(x: 10, y: 10), accuracy: 0.0001, "圆弧终点")
        // 中点应落在圆弧上：t=0.5 处约 (7.07, 2.93)。
        let (c1, c2, e) = segments[0]
        let mid = cubicMidpoint(c1, c2, e)
        assertPoint(mid, CGPoint(x: 10 * 0.7071, y: 10 - 10 * 0.7071), accuracy: 0.02, "圆弧中点")
    }

    func test_arc_largeArcFlagChoosesOtherCenter() {
        // 同一端点与半径，large-arc=1 时圆弧过半圆，中点应在另一侧。
        let small = SVGPathParser.arcToBeziers(
            from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 10),
            radiusX: 10, radiusY: 10, rotationDegrees: 0,
            largeArc: false, sweep: true
        )
        let large = SVGPathParser.arcToBeziers(
            from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 10),
            radiusX: 10, radiusY: 10, rotationDegrees: 0,
            largeArc: true, sweep: true
        )
        XCTAssertEqual(small.count, 1)
        XCTAssertGreaterThan(large.count, 1, "大半圆弧应分段为多段三次贝塞尔")
        let smallMid = cubicMidpoint(small[0].0, small[0].1, small[0].2)
        let largeMid = cubicMidpoint(large[0].0, large[0].1, large[0].2)
        // 大半圆弧走另一侧圆心（(10,0)），首段中点与小圆弧中点应明显分离。
        let distance = hypot(largeMid.x - smallMid.x, largeMid.y - smallMid.y)
        XCTAssertGreaterThan(distance, 8, "大小圆弧应走不同侧")
    }

    // MARK: - 真实品牌 logo 数据

    func test_allProvidersHaveParseableBrandLogo() {
        for provider in TokenUsageProvider.allCases {
            let layers = provider.brandLogo
            if provider == .dsh {
                // DSH 为本地自有工具，无公开品牌 logo，保持字母占位。
                XCTAssertNil(layers, "\(provider) 不应有品牌 logo")
                continue
            }
            guard let layers, !layers.isEmpty else {
                return XCTFail("\(provider) 缺少品牌 logo")
            }
            for (index, layer) in layers.enumerated() {
                var parser = SVGPathParser(data: layer.pathData)
                let commands = parser.parse()
                XCTAssertFalse(commands.isEmpty, "\(provider) 第 \(index) 层解析为空")
                XCTAssertTrue(layer.opacity > 0 && layer.opacity <= 1)
            }
        }
    }

    func test_brandLogoRendersInside24Box() {
        // 归一化坐标应落在 24x24 viewBox 附近（控制点允许轻微越界）。
        for provider in TokenUsageProvider.allCases {
            guard let layers = provider.brandLogo else { continue }
            let rect = CGRect(x: 0, y: 0, width: 24, height: 24)
            for layer in layers {
                let shape = SVGPathShape(pathData: layer.pathData)
                let path = shape.path(in: rect)
                let bounds = path.boundingRect
                XCTAssertGreaterThanOrEqual(bounds.minX, -3, "\(provider) minX 越界")
                XCTAssertGreaterThanOrEqual(bounds.minY, -3, "\(provider) minY 越界")
                XCTAssertLessThanOrEqual(bounds.maxX, 27, "\(provider) maxX 越界")
                XCTAssertLessThanOrEqual(bounds.maxY, 27, "\(provider) maxY 越界")
            }
        }
    }

    func test_brandColorAvailableForEveryProvider() {
        // 每个 provider 都有品牌色（DSH 沿用占位青）。
        for provider in TokenUsageProvider.allCases {
            _ = provider.brandColor
        }
    }

    // MARK: - 辅助

    private func cubicMidpoint(_ c1: CGPoint, _ c2: CGPoint, _ end: CGPoint) -> CGPoint {
        let start = CGPoint.zero
        let t: CGFloat = 0.5
        let mt = 1 - t
        let x = mt * mt * mt * start.x + 3 * mt * mt * t * c1.x + 3 * mt * t * t * c2.x + t * t * t * end.x
        let y = mt * mt * mt * start.y + 3 * mt * mt * t * c1.y + 3 * mt * t * t * c2.y + t * t * t * end.y
        return CGPoint(x: x, y: y)
    }

    private func assertPoint(
        _ lhs: CGPoint, _ rhs: CGPoint, accuracy: CGFloat,
        _ message: String = "", file: StaticString = #filePath, line: UInt = #line
    ) {
        if abs(lhs.x - rhs.x) >= accuracy || abs(lhs.y - rhs.y) >= accuracy {
            XCTFail("\(lhs) != \(rhs) (accuracy \(accuracy)) \(message)", file: file, line: line)
        }
    }
}

/// 图标渲染冒烟测试：品牌色底板与 logo 字形真实可见。
extension SVGPathShapeTests {
    @MainActor
    func test_iconRendersBrandColorAndGlyph() {
        for provider in TokenUsageProvider.allCases {
            let size: CGFloat = 32
            let view = TokenUsageProviderIconView(provider: provider, size: size, cornerRadius: 8)
                .frame(width: size, height: size)
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = .init(width: size, height: size)
            guard let image = renderer.nsImage else {
                return XCTFail("\(provider) 渲染失败")
            }
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return XCTFail("\(provider) 无法取位图")
            }
            let pixels = rasterize(cgImage)
            XCTAssertFalse(pixels.isEmpty, "\(provider) 无像素")
            let opaque = pixels.filter { $0.a > 200 }.count
            XCTAssertGreaterThan(opaque, pixels.count / 2, "\(provider) 底板未填满")

            if provider == .dsh {
                // 字母占位：存在与底板色不同的前景像素即可。
                let bg = pixels.first { $0.a > 200 }?.rgb ?? (0, 0, 0)
                let fg = pixels.filter { $0.a > 200 && differs($0.rgb, bg, threshold: 60) }.count
                XCTAssertGreaterThan(fg, 10, "\(provider) 前景字母不可见")
            } else {
                // 真实 logo：白/彩色字形应与品牌色底板显著不同。
                let bg = pixels.first { $0.a > 200 }?.rgb ?? (0, 0, 0)
                let fg = pixels.filter { $0.a > 200 && differs($0.rgb, bg, threshold: 60) }.count
                XCTAssertGreaterThan(fg, 20, "\(provider) logo 字形不可见")
            }
        }
    }

    // MARK: - 光栅化辅助

    private func rasterize(_ image: CGImage) -> [(rgb: (Int, Int, Int), a: Int)] {
        let width = image.width
        let height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &data, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var pixels: [(rgb: (Int, Int, Int), a: Int)] = []
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels.append(((Int(data[i]), Int(data[i+1]), Int(data[i+2])), Int(data[i+3])))
            }
        }
        return pixels
    }

    private func differs(_ a: (Int, Int, Int), _ b: (Int, Int, Int), threshold: Int) -> Bool {
        abs(a.0 - b.0) > threshold || abs(a.1 - b.1) > threshold || abs(a.2 - b.2) > threshold
    }
}
