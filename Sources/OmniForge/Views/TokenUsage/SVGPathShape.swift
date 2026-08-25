import SwiftUI

// MARK: - SVG Path 解析

/// SVG path data 解析后的绝对坐标命令（仅保留渲染所需的最小命令集）。
enum SVGPathCommand: Equatable {
    case moveTo(CGPoint)
    case lineTo(CGPoint)
    case cubicTo(control1: CGPoint, control2: CGPoint, end: CGPoint)
    case closeSubpath
}

/// SVG `<path d="...">` 解析器。
///
/// 支持 M/m、L/l、H/h、V/v、C/c、S/s、Q/q、T/t、A/a、Z/z，包含相对坐标、隐式重复参数、
/// 圆弧标志位（单字符 0/1，可紧贴相连如 `01`）与圆弧转三次贝塞尔。
/// 坐标按 viewBox 0 0 24 24 解释；品牌 logo 数据已预归一化到该空间。
struct SVGPathParser {
    private let chars: [Character]
    private var index: Int

    init(data: String) {
        self.chars = Array(data)
        self.index = 0
    }

    // MARK: - 解析

    mutating func parse() -> [SVGPathCommand] {
        var out: [SVGPathCommand] = []
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        // 上一条曲线的第二个控制点（用于 S/T 镜像反射；M/L/H/V/Z 后失效）。
        var lastControl: CGPoint?

        while let cmd = nextCommand() {
            switch cmd {
            case "M", "m":
                var first = true
                while let pair = nextNumberPair() {
                    let target = cmd == "m" ? add(pair, to: current) : pair
                    if first {
                        out.append(.moveTo(target))
                        subpathStart = target
                        first = false
                    } else {
                        out.append(.lineTo(target))
                    }
                    current = target
                    lastControl = nil
                }

            case "L", "l":
                while let pair = nextNumberPair() {
                    let target = cmd == "l" ? add(pair, to: current) : pair
                    out.append(.lineTo(target))
                    current = target
                    lastControl = nil
                }

            case "H", "h":
                while let value = nextNumber() {
                    let target = CGPoint(
                        x: cmd == "h" ? current.x + value : value,
                        y: current.y
                    )
                    out.append(.lineTo(target))
                    current = target
                    lastControl = nil
                }

            case "V", "v":
                while let value = nextNumber() {
                    let target = CGPoint(
                        x: current.x,
                        y: cmd == "v" ? current.y + value : value
                    )
                    out.append(.lineTo(target))
                    current = target
                    lastControl = nil
                }

            case "C", "c":
                while let six = nextNumbers(6) {
                    var c1 = CGPoint(x: six[0], y: six[1])
                    var c2 = CGPoint(x: six[2], y: six[3])
                    var end = CGPoint(x: six[4], y: six[5])
                    if cmd == "c" {
                        c1 = add(c1, to: current)
                        c2 = add(c2, to: current)
                        end = add(end, to: current)
                    }
                    out.append(.cubicTo(control1: c1, control2: c2, end: end))
                    current = end
                    lastControl = c2
                }

            case "S", "s":
                while let four = nextNumbers(4) {
                    var c2 = CGPoint(x: four[0], y: four[1])
                    var end = CGPoint(x: four[2], y: four[3])
                    if cmd == "s" {
                        c2 = add(c2, to: current)
                        end = add(end, to: current)
                    }
                    let c1 = reflectedControl(lastControl, from: current)
                    out.append(.cubicTo(control1: c1, control2: c2, end: end))
                    current = end
                    lastControl = c2
                }

            case "Q", "q":
                while let four = nextNumbers(4) {
                    var quad = CGPoint(x: four[0], y: four[1])
                    var end = CGPoint(x: four[2], y: four[3])
                    if cmd == "q" {
                        quad = add(quad, to: current)
                        end = add(end, to: current)
                    }
                    // 二次贝塞尔 → 三次贝塞尔
                    let c1 = CGPoint(
                        x: current.x + (quad.x - current.x) * 2 / 3,
                        y: current.y + (quad.y - current.y) * 2 / 3
                    )
                    let c2 = CGPoint(
                        x: end.x + (quad.x - end.x) * 2 / 3,
                        y: end.y + (quad.y - end.y) * 2 / 3
                    )
                    out.append(.cubicTo(control1: c1, control2: c2, end: end))
                    current = end
                    lastControl = quad
                }

            case "T", "t":
                while let pair = nextNumberPair() {
                    let end = cmd == "t" ? add(pair, to: current) : pair
                    let quad = reflectedControl(lastControl, from: current)
                    let c1 = CGPoint(
                        x: current.x + (quad.x - current.x) * 2 / 3,
                        y: current.y + (quad.y - current.y) * 2 / 3
                    )
                    let c2 = CGPoint(
                        x: end.x + (quad.x - end.x) * 2 / 3,
                        y: end.y + (quad.y - end.y) * 2 / 3
                    )
                    out.append(.cubicTo(control1: c1, control2: c2, end: end))
                    current = end
                    lastControl = quad
                }

            case "A", "a":
                while let arc = nextArc() {
                    var end = CGPoint(x: arc.end.x, y: arc.end.y)
                    if cmd == "a" {
                        end = add(end, to: current)
                    }
                    let segments = Self.arcToBeziers(
                        from: current,
                        to: end,
                        radiusX: arc.radiusX,
                        radiusY: arc.radiusY,
                        rotationDegrees: arc.rotation,
                        largeArc: arc.largeArc,
                        sweep: arc.sweep
                    )
                    for (c1, c2, e) in segments {
                        out.append(.cubicTo(control1: c1, control2: c2, end: e))
                    }
                    current = end
                    lastControl = nil
                }

            case "Z", "z":
                out.append(.closeSubpath)
                current = subpathStart
                lastControl = nil

            default:
                break
            }
        }
        return out
    }

    // MARK: - 扫描

    private mutating func nextCommand() -> Character? {
        skipSeparators()
        guard index < chars.count else { return nil }
        let ch = chars[index]
        guard isCommandLetter(ch) else { return nil }
        index += 1
        return ch
    }

    /// 读取一个数字；若下一个是非数字/命令则返回 nil（用于判断参数组是否结束）。
    private mutating func nextNumber() -> Double? {
        skipSeparators()
        let start = index
        var i = index
        let n = chars.count
        if i < n, chars[i] == "+" || chars[i] == "-" {
            i += 1
        }
        var seenDot = false
        var hasDigit = false
        while i < n {
            let c = chars[i]
            if c.isNumber {
                hasDigit = true
                i += 1
            } else if c == ".", !seenDot {
                seenDot = true
                i += 1
            } else {
                break
            }
        }
        if i < n, chars[i] == "e" || chars[i] == "E" {
            var j = i + 1
            if j < n, chars[j] == "+" || chars[j] == "-" {
                j += 1
            }
            if j < n, chars[j].isNumber {
                while j < n, chars[j].isNumber {
                    j += 1
                }
                i = j
            }
        }
        guard hasDigit, i > start else { return nil }
        guard let value = Double(String(chars[start..<i])) else { return nil }
        index = i
        return value
    }

    private mutating func nextNumberPair() -> CGPoint? {
        guard let x = nextNumber() else { return nil }
        guard let y = nextNumber() else { return nil }
        return CGPoint(x: x, y: y)
    }

    private mutating func nextNumbers(_ count: Int) -> [CGFloat]? {
        var values: [CGFloat] = []
        for _ in 0..<count {
            guard let v = nextNumber() else { return nil }
            values.append(v)
        }
        return values
    }

    /// 读取弧段：rx ry rot 三个数字 + 两个单字符标志位 + 终点。
    private mutating func nextArc() -> ArcParams? {
        guard let rx = nextNumber(),
              let ry = nextNumber(),
              let rotation = nextNumber()
        else { return nil }
        guard let largeArc = nextFlag(),
              let sweep = nextFlag()
        else { return nil }
        guard let end = nextNumberPair() else { return nil }
        return ArcParams(
            radiusX: rx, radiusY: ry, rotation: rotation,
            largeArc: largeArc, sweep: sweep, end: end
        )
    }

    /// 圆弧标志位：单个字符 0/1（可紧贴相连，如 `01` 表示 0 与 1）。
    private mutating func nextFlag() -> Bool? {
        skipSeparators()
        guard index < chars.count else { return nil }
        let c = chars[index]
        if c == "0" {
            index += 1
            return false
        }
        if c == "1" {
            index += 1
            return true
        }
        return nil
    }

    private mutating func skipSeparators() {
        while index < chars.count {
            let c = chars[index]
            if c.isWhitespace || c == "," {
                index += 1
            } else {
                break
            }
        }
    }

    private func isCommandLetter(_ c: Character) -> Bool {
        "MmLlHhVvCcSsQqTtAaZz".contains(c)
    }

    private func add(_ p: CGPoint, to base: CGPoint) -> CGPoint {
        CGPoint(x: base.x + p.x, y: base.y + p.y)
    }

    /// S/T 的镜像控制点：反射上一段曲线的控制点，否则为当前点。
    private func reflectedControl(_ last: CGPoint?, from current: CGPoint) -> CGPoint {
        guard let last else { return current }
        return CGPoint(x: 2 * current.x - last.x, y: 2 * current.y - last.y)
    }

    // MARK: - 圆弧

    private struct ArcParams {
        let radiusX: CGFloat
        let radiusY: CGFloat
        let rotation: CGFloat
        let largeArc: Bool
        let sweep: Bool
        let end: CGPoint
    }

    /// SVG 圆弧 → 三次贝塞尔（端点参数化转圆心参数化，按 ≤90° 分段）。
    static func arcToBeziers(
        from start: CGPoint,
        to end: CGPoint,
        radiusX: CGFloat,
        radiusY: CGFloat,
        rotationDegrees: CGFloat,
        largeArc: Bool,
        sweep: Bool
    ) -> [(control1: CGPoint, control2: CGPoint, end: CGPoint)] {
        if start == end { return [] }
        if radiusX == 0 || radiusY == 0 {
            return [(start, start, end)]
        }

        let phi = rotationDegrees * .pi / 180
        let sinPhi = sin(phi)
        let cosPhi = cos(phi)
        let dx = (start.x - end.x) / 2
        let dy = (start.y - end.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy

        var rx = abs(radiusX)
        var ry = abs(radiusY)
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let s = sqrt(lambda)
            rx *= s
            ry *= s
        }

        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = den > 0 ? sqrt(max(0, num / den)) : 0
        if largeArc == sweep {
            coef = -coef
        }
        let cxp = coef * (rx * y1p / ry)
        let cyp = coef * (-ry * x1p / rx)
        let center = CGPoint(
            x: cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2,
            y: sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2
        )

        let ux = (x1p - cxp) / rx
        let uy = (y1p - cyp) / ry
        let vx = (-x1p - cxp) / rx
        let vy = (-y1p - cyp) / ry
        var theta1 = Self.angle(1, 0, ux, uy)
        var deltaTheta = Self.angle(ux, uy, vx, vy)
        if !sweep, deltaTheta > 0 {
            deltaTheta -= 2 * .pi
        } else if sweep, deltaTheta < 0 {
            deltaTheta += 2 * .pi
        }

        let segments = max(1, Int(ceil(abs(deltaTheta) / (.pi / 2))))
        let delta = deltaTheta / CGFloat(segments)
        var result: [(CGPoint, CGPoint, CGPoint)] = []
        for _ in 0..<segments {
            let theta2 = theta1 + delta
            let k = 4 / 3 * tan(delta / 4)
            var c1 = CGPoint(
                x: center.x + rx * cos(theta1) - k * rx * sin(theta1),
                y: center.y + ry * sin(theta1) + k * ry * cos(theta1)
            )
            var c2 = CGPoint(
                x: center.x + rx * cos(theta2) + k * rx * sin(theta2),
                y: center.y + ry * sin(theta2) - k * ry * cos(theta2)
            )
            var e = CGPoint(
                x: center.x + rx * cos(theta2),
                y: center.y + ry * sin(theta2)
            )
            // 旋转回原坐标系
            c1 = Self.rotate(c1, around: center, sinPhi: sinPhi, cosPhi: cosPhi)
            c2 = Self.rotate(c2, around: center, sinPhi: sinPhi, cosPhi: cosPhi)
            e = Self.rotate(e, around: center, sinPhi: sinPhi, cosPhi: cosPhi)
            result.append((c1, c2, e))
            theta1 = theta2
        }
        return result
    }

    private static func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
        let dot = ux * vx + uy * vy
        let length = hypot(ux, uy) * hypot(vx, vy)
        guard length > 0 else { return 0 }
        var a = acos(min(1, max(-1, dot / length)))
        if ux * vy - uy * vx < 0 {
            a = -a
        }
        return a
    }

    private static func rotate(_ p: CGPoint, around center: CGPoint, sinPhi: CGFloat, cosPhi: CGFloat) -> CGPoint {
        CGPoint(
            x: center.x + cosPhi * (p.x - center.x) - sinPhi * (p.y - center.y),
            y: center.y + sinPhi * (p.x - center.x) + cosPhi * (p.y - center.y)
        )
    }
}

// MARK: - Shape

/// 把 SVG path data（viewBox 0 0 24 24）映射到目标矩形的 Shape。
/// 填充规则（evenodd）由调用方通过 `FillStyle(eoFill:)` 控制。
struct SVGPathShape: Shape {
    let pathData: String

    func path(in rect: CGRect) -> Path {
        var parser = SVGPathParser(data: pathData)
        let commands = parser.parse()

        var viewBoxPath = Path()
        for command in commands {
            switch command {
            case .moveTo(let p):
                viewBoxPath.move(to: p)
            case .lineTo(let p):
                viewBoxPath.addLine(to: p)
            case .cubicTo(let c1, let c2, let end):
                viewBoxPath.addCurve(to: end, control1: c1, control2: c2)
            case .closeSubpath:
                viewBoxPath.closeSubpath()
            }
        }

        let scale = min(rect.width, rect.height) / 24
        let tx = rect.midX - 12 * scale
        let ty = rect.midY - 12 * scale
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: tx, ty: ty)
        return viewBoxPath.applying(transform)
    }
}
