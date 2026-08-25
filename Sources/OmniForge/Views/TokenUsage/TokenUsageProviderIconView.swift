import SwiftUI

/// Token 供应商 18x18 品牌 App 图标组件。
/// 对齐最新参考 UI 规范（DeepSeek 蓝白气泡、Codex 黑底白标、Kimi 紫底白 K、Antigravity 趋势图表、Cursor 黑底白箭头等）。
struct TokenUsageProviderIconView: View {
    let provider: TokenUsageProvider
    var size: CGFloat = 18
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
            Color(red: 0x4D / 255.0, green: 0x6B / 255.0, blue: 0xFE / 255.0)
        case .codex:
            Color(red: 0x1C / 255.0, green: 0x1C / 255.0, blue: 0x1E / 255.0)
        case .kimi:
            Color(red: 0x5B / 255.0, green: 0x5B / 255.0, blue: 0xD6 / 255.0)
        case .antigravity:
            if colorScheme == .dark {
                Color(red: 0x2C / 255.0, green: 0x2C / 255.0, blue: 0x2E / 255.0)
            } else {
                Color.white
            }
        case .cursor:
            Color(red: 0x1C / 255.0, green: 0x1C / 255.0, blue: 0x1E / 255.0)
        case .claude:
            Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
        case .grok:
            Color(red: 0x11 / 255.0, green: 0x18 / 255.0, blue: 0x27 / 255.0)
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

    // MARK: - 内部图标

    @ViewBuilder
    private var iconContent: some View {
        switch provider {
        case .deepSeek:
            // 蓝底白气泡
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundColor(.white)

        case .codex:
            // 黑底白螺旋/OpenAI 符号
            CodexSpiralIcon()
                .stroke(Color.white, lineWidth: 1.5)
                .frame(width: 10, height: 10)

        case .kimi:
            // 紫底白 K
            Text("K")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundColor(.white)

        case .antigravity:
            // 白底彩色趋势折线
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 10, weight: .bold))
                .symbolRenderingMode(.multicolor)
                .foregroundStyle(Color(red: 0x0A / 255.0, green: 0x84 / 255.0, blue: 0xFF / 255.0))

        case .cursor:
            // 黑底白箭头
            Image(systemName: "location.north.fill")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundColor(.white)
                .rotationEffect(.degrees(-45))

        case .claude:
            // 橙底白星芒
            Image(systemName: "sparkle")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)

        case .grok:
            // 黑底白 X
            Text("X")
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundColor(.white)

        case .traeCN:
            Text("T")
                .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                .foregroundColor(.white)

        case .opencode:
            Image(systemName: "curlybraces")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)

        case .codebuddy, .workbuddy, .zcode, .qoder, .dsh, .arkCodingPlan:
            Text(providerLetter)
                .font(.system(size: 10, weight: .bold, design: .rounded))
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

/// Codex 极简螺旋徽标（类似 OpenAI 花瓣/螺旋符号）。
private struct CodexSpiralIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2.2
        path.addArc(center: center, radius: radius, startAngle: .degrees(45), endAngle: .degrees(315), clockwise: false)
        path.addArc(center: CGPoint(x: center.x, y: center.y - 1), radius: radius * 0.5, startAngle: .degrees(315), endAngle: .degrees(135), clockwise: true)
        return path
    }
}
