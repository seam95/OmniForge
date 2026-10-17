import SwiftUI

/// 供应商卡片中统一使用的品牌 Logo 徽章视图（支持真实矢量 Logo 与首字母徽章兜底，支持自定义尺寸与圆角）。
struct ProviderBrandLogoBadge: View {
    let visual: ProviderBrandVisual.Visual
    var size: CGFloat = ProviderCardVisual.logoSize
    var cornerRadius: CGFloat = ProviderCardVisual.logoCornerRadius

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(visual.containerColor ?? visual.color)
                .frame(width: size, height: size)
            if let logo = visual.logo {
                ProviderLogoGlyphView(layers: logo, fill: AnyShapeStyle(visual.logoTint ?? .white))
                    .frame(width: size, height: size)
            } else {
                Text(visual.letter)
                    .font(.system(size: size * 0.48, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
    }
}
