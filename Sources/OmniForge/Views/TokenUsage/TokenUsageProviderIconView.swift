import SwiftUI

/// Token 供应商 16x16 真实品牌 App 图标组件。
/// 规范：16x16 pt，4pt 圆角，真实厂商官方矢量 logo（2026-08-25 起替换手绘近似符号）。
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

    // MARK: - 品牌色底板

    private var backgroundFill: Color {
        provider.brandColor
    }

    private var strokeBorderColor: Color {
        if provider == .antigravity {
            return Color.primary.opacity(0.12)
        }
        return Color.black.opacity(0.06)
    }

    // MARK: - 真实厂商 logo

    @ViewBuilder
    private var iconContent: some View {
        if provider == .dsh {
            // DSH 为本地自有工具，无公开品牌，沿用字母占位。
            Text("D")
                .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
        } else if let logo = provider.brandLogo {
            if provider == .antigravity {
                // Antigravity 官方图标为「g」字形 + Google 四色环形渐变（左上黄/右上红/右下蓝/左下绿）。
                ProviderLogoGlyphView(layers: logo, fill: AnyShapeStyle(googleStarGradient))
            } else {
                ProviderLogoGlyphView(layers: logo)
            }
        }
    }

    /// Google 品牌四色（Antigravity 的 2025 新版平滑渐变，顺时针：红→黄→绿→蓝）。
    private var googleStarGradient: AngularGradient {
        AngularGradient(
            gradient: Gradient(colors: [
                Color(red: 0x42 / 255.0, green: 0x85 / 255.0, blue: 0xF4 / 255.0), // 蓝
                Color(red: 0x34 / 255.0, green: 0xA8 / 255.0, blue: 0x53 / 255.0), // 绿
                Color(red: 0xFB / 255.0, green: 0xBC / 255.0, blue: 0x04 / 255.0), // 黄
                Color(red: 0xEA / 255.0, green: 0x43 / 255.0, blue: 0x35 / 255.0), // 红
                Color(red: 0x42 / 255.0, green: 0x85 / 255.0, blue: 0xF4 / 255.0), // 蓝（闭合）
            ]),
            center: .center,
            startAngle: .degrees(45),   // 右下蓝
            endAngle: .degrees(405)
        )
    }
}

// MARK: - Logo 渲染

/// 在品牌色底板上渲染真实 logo 图层（默认白色，可注入任意填充如渐变）。
struct ProviderLogoGlyphView: View {
    let layers: [ProviderLogoLayer]
    var fill: AnyShapeStyle = AnyShapeStyle(.white)
    /// 字形相对底板的收缩比例（保证 16pt 下不贴边）。
    var insetFraction: CGFloat = 0.18

    var body: some View {
        GeometryReader { proxy in
            let edge = min(proxy.size.width, proxy.size.height) * (1 - 2 * insetFraction)
            ZStack {
                ForEach(layers.indices, id: \.self) { index in
                    SVGPathShape(pathData: layers[index].pathData)
                        .fill(fill.opacity(layers[index].opacity), style: FillStyle(eoFill: true))
                }
            }
            .frame(width: edge, height: edge)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - 品牌色

extension TokenUsageProvider {
    /// 品牌色（图标底板 / 深色 logo 的背景色），对齐各厂商官方视觉（2026-08-25 校准）。
    var brandColor: Color {
        switch self {
        case .claude: return Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
        case .codex: return Color(red: 0x10 / 255.0, green: 0x10 / 255.0, blue: 0x10 / 255.0)
        case .antigravity: return Color(red: 0x14 / 255.0, green: 0x14 / 255.0, blue: 0x16 / 255.0)
        case .kimi: return Color(red: 0x5B / 255.0, green: 0x5B / 255.0, blue: 0xD6 / 255.0)
        case .cursor: return Color(red: 0x10 / 255.0, green: 0x10 / 255.0, blue: 0x10 / 255.0)
        case .deepSeek: return Color(red: 0x4D / 255.0, green: 0x6B / 255.0, blue: 0xF5 / 255.0)
        case .opencode: return Color(red: 0x10 / 255.0, green: 0x10 / 255.0, blue: 0x10 / 255.0)
        case .codebuddy: return Color(red: 0x6C / 255.0, green: 0x4D / 255.0, blue: 0xFF / 255.0)
        case .workbuddy: return Color(red: 0x0E / 255.0, green: 0xA5 / 255.0, blue: 0xE9 / 255.0)
        case .grok: return Color(red: 0x11 / 255.0, green: 0x18 / 255.0, blue: 0x27 / 255.0)
        case .zcode: return Color(red: 0x67 / 255.0, green: 0x50 / 255.0, blue: 0xF8 / 255.0)
        case .traeCN: return Color(red: 0x10 / 255.0, green: 0x10 / 255.0, blue: 0x10 / 255.0)
        case .qoder: return Color(red: 0x8B / 255.0, green: 0x5C / 255.0, blue: 0xF6 / 255.0)
        case .dsh: return Color(red: 0x14 / 255.0, green: 0xB8 / 255.0, blue: 0xA6 / 255.0)
        case .arkCodingPlan: return Color(red: 0x3C / 255.0, green: 0x8C / 255.0, blue: 0xFF / 255.0)
        }
    }
}
