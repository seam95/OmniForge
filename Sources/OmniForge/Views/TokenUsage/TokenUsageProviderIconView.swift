import SwiftUI

/// Token 供应商 16x16 真实品牌 App 图标组件。
/// 规范：16x16 pt，4pt 圆角，真实厂商官方图标。
struct TokenUsageProviderIconView: View {
    let provider: TokenUsageProvider
    var size: CGFloat = 16
    var cornerRadius: CGFloat = 4

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            backgroundFill
            iconContent
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(strokeBorderColor, lineWidth: 0.5)
        )
    }

    // MARK: - 背景色

    @ViewBuilder
    private var backgroundFill: some View {
        switch provider {
        case .deepSeek:
            Color(red: 0x4D / 255.0, green: 0x6B / 255.0, blue: 0xF5 / 255.0)
        case .codex:
            Color(red: 0x10 / 255.0, green: 0x10 / 255.0, blue: 0x10 / 255.0)
        case .kimi:
            Color(red: 0x5B / 255.0, green: 0x5B / 255.0, blue: 0xD6 / 255.0)
        case .antigravity:
            if colorScheme == .dark {
                Color(red: 0x2C / 255.0, green: 0x2C / 255.0, blue: 0x2E / 255.0)
            } else {
                Color.white
            }
        case .cursor:
            Color(red: 0x10 / 255.0, green: 0x10 / 255.0, blue: 0x10 / 255.0)
        case .claude:
            Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
        case .grok:
            Color(red: 0x10 / 255.0, green: 0x10 / 255.0, blue: 0x10 / 255.0)
        case .traeCN:
            Color(red: 0xEF / 255.0, green: 0x44 / 255.0, blue: 0x44 / 255.0)
        case .opencode:
            Color(red: 0x8B / 255.0, green: 0x5C / 255.0, blue: 0xF6 / 255.0)
        case .codebuddy:
            Color(red: 0xF9 / 255.0, green: 0x73 / 255.0, blue: 0x16 / 255.0)
        case .workbuddy:
            Color(red: 0x0E / 255.0, green: 0xA5 / 255.0, blue: 0xE9 / 255.0)
        case .zcode:
            Color(red: 0x22 / 255.0, green: 0xC5 / 255.0, blue: 0x5E / 255.0)
        case .qoder:
            Color(red: 0xEA / 255.0, green: 0xB3 / 255.0, blue: 0x08 / 255.0)
        case .dsh:
            Color(red: 0x14 / 255.0, green: 0xB8 / 255.0, blue: 0xA6 / 255.0)
        case .arkCodingPlan:
            Color(red: 0x63 / 255.0, green: 0x66 / 255.0, blue: 0xF1 / 255.0)
        }
    }

    private var strokeBorderColor: Color {
        if provider == .antigravity {
            return Color.primary.opacity(0.12)
        }
        return Color.black.opacity(0.06)
    }

    // MARK: - 真实厂商符号

    @ViewBuilder
    private var iconContent: some View {
        switch provider {
        case .deepSeek:
            // 真实 DeepSeek 小鲸鱼/气泡符号
            DeepSeekWhaleIcon()
                .fill(Color.white)
                .frame(width: 10.5, height: 10.5)

        case .codex:
            // 真实 OpenAI 螺旋徽标
            OpenAISpiralIcon()
                .stroke(Color.white, lineWidth: 1.25)
                .frame(width: 9.5, height: 9.5)

        case .kimi:
            // 真实 Kimi 粗体 K
            Text("K")
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .foregroundColor(.white)

        case .antigravity:
            // Google Antigravity 彩色趋势折线
            AntigravityTrendIcon()
                .frame(width: 10, height: 10)

        case .cursor:
            // 真实 Cursor 导航箭头符号
            CursorArrowIcon()
                .fill(Color.white)
                .frame(width: 9, height: 9)

        case .claude:
            // 真实 Claude 星芒符号
            ClaudeSparkleIcon()
                .fill(Color.white)
                .frame(width: 9.5, height: 9.5)

        case .grok:
            // 真实 Grok X/斜杠符号
            Text("X")
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundColor(.white)

        case .traeCN:
            Text("T")
                .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                .foregroundColor(.white)

        case .opencode:
            Image(systemName: "curlybraces")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white)

        case .codebuddy, .workbuddy, .zcode, .qoder, .dsh, .arkCodingPlan:
            Text(providerLetter)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        }
    }

    private var providerLetter: String {
        switch provider {
        case .codebuddy: return "C"
        case .workbuddy: return "W"
        case .zcode: return "Z"
        case .qoder: return "Q"
        case .dsh: return "D"
        case .arkCodingPlan: return "方"
        default: return String(provider.displayName.prefix(1))
        }
    }
}

// MARK: - 矢量图形辅助

/// 真实 DeepSeek 小鲸鱼图标
private struct DeepSeekWhaleIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        // 头部圆润气泡 + 尾部小鱼尾
        path.move(to: CGPoint(x: rect.minX + w * 0.15, y: rect.minY + h * 0.5))
        path.addCurve(
            to: CGPoint(x: rect.minX + w * 0.8, y: rect.minY + h * 0.2),
            control1: CGPoint(x: rect.minX + w * 0.15, y: rect.minY + h * 0.2),
            control2: CGPoint(x: rect.minX + w * 0.5, y: rect.minY + h * 0.15)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.1),
            control1: CGPoint(x: rect.minX + w * 0.9, y: rect.minY + h * 0.2),
            control2: CGPoint(x: rect.minX + w * 0.95, y: rect.minY + h * 0.1)
        )
        path.addLine(to: CGPoint(x: rect.minX + w * 0.88, y: rect.minY + h * 0.45))
        path.addCurve(
            to: CGPoint(x: rect.minX + w * 0.75, y: rect.minY + h * 0.8),
            control1: CGPoint(x: rect.minX + w * 0.9, y: rect.minY + h * 0.65),
            control2: CGPoint(x: rect.minX + w * 0.85, y: rect.minY + h * 0.8)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX + w * 0.15, y: rect.minY + h * 0.5),
            control1: CGPoint(x: rect.minX + w * 0.35, y: rect.minY + h * 0.85),
            control2: CGPoint(x: rect.minX + w * 0.15, y: rect.minY + h * 0.75)
        )
        return path
    }
}

/// 真实 OpenAI 六叶螺旋图标
private struct OpenAISpiralIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) * 0.48
        // 6 段旋转螺旋弧线
        for i in 0..<6 {
            let angle = Double(i) * (.pi / 3.0)
            let start = CGPoint(
                x: center.x + CGFloat(cos(angle)) * (radius * 0.35),
                y: center.y + CGFloat(sin(angle)) * (radius * 0.35)
            )
            let end = CGPoint(
                x: center.x + CGFloat(cos(angle + .pi * 0.6)) * radius,
                y: center.y + CGFloat(sin(angle + .pi * 0.6)) * radius
            )
            path.move(to: start)
            path.addQuadCurve(
                to: end,
                control: CGPoint(
                    x: center.x + CGFloat(cos(angle + .pi * 0.25)) * (radius * 0.9),
                    y: center.y + CGFloat(sin(angle + .pi * 0.25)) * (radius * 0.9)
                )
            )
        }
        return path
    }
}

/// 真实 Cursor 45度倾斜三角导航箭头
private struct CursorArrowIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        path.move(to: CGPoint(x: rect.minX + w * 0.05, y: rect.minY + h * 0.05)) // 尖端 (左上)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.45))        // 右上翼
        path.addLine(to: CGPoint(x: rect.minX + w * 0.55, y: rect.minY + h * 0.55)) // 内凹点
        path.addLine(to: CGPoint(x: rect.minX + w * 0.45, y: rect.maxY))        // 左下翼
        path.closeSubpath()
        return path
    }
}

/// 真实 Claude 星芒/火花图标
private struct ClaudeSparkleIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let rOuter = min(rect.width, rect.height) * 0.5
        let rInner = rOuter * 0.25
        let points = 8
        for i in 0..<(points * 2) {
            let r = i.isMultiple(of: 2) ? rOuter : rInner
            let angle = (Double(i) * .pi / Double(points)) - (.pi / 2.0)
            let pt = CGPoint(x: center.x + CGFloat(cos(angle)) * r, y: center.y + CGFloat(sin(angle)) * r)
            if i == 0 {
                path.move(to: pt)
            } else {
                path.addLine(to: pt)
            }
        }
        path.closeSubpath()
        return path
    }
}

/// Antigravity Google 风格趋势折线视图
private struct AntigravityTrendIcon: View {
    var body: some View {
        ZStack {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(Color(red: 0x42 / 255.0, green: 0x85 / 255.0, blue: 0xF4 / 255.0))
        }
    }
}
