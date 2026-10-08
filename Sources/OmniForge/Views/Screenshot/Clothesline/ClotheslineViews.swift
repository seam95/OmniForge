import SwiftUI

/// 命中区上报：卡片帧（全局坐标）汇总给面板做穿透切换。
struct HitRectsKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// 绳子本体：中性灰主线 + 顶部高光 + 柔影，两端渐隐。
private struct RopeShape: View {
    let width: CGFloat

    private var path: Path {
        Path { p in
            let top = ClotheslineLayout.ropeTop
            p.move(to: CGPoint(x: -20, y: top))
            p.addQuadCurve(
                to: CGPoint(x: width + 20, y: top),
                control: CGPoint(x: width / 2, y: top + 2 * ClotheslineLayout.sag(width: width)))
        }
    }

    var body: some View {
        ZStack {
            path.stroke(Color.black.opacity(0.22), lineWidth: 1.4).offset(y: 1.2).blur(radius: 1.2)
            path.stroke(Color(white: 0.55), lineWidth: 1.2)
            path.stroke(Color.white.opacity(0.45), lineWidth: 0.4).offset(y: -0.35)
        }
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.08),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing))
        .allowsHitTesting(false)
    }
}

/// 绳 + 照片阵列。藏起时整体上移出顶边（自动隐藏 Dock 的滑出方式）。
struct ClotheslineView: View {
    @ObservedObject var manager: ClotheslineManager
    var emptyHint: String = ""
    var menuProvider: ((PeggedPhoto) -> NSMenu)? = nil

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                RopeShape(width: width)
                if manager.items.isEmpty, !emptyHint.isEmpty {
                    Text(emptyHint)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .position(x: width / 2,
                                  y: ClotheslineLayout.ropeY(x: width / 2, width: width) + 34)
                        .transition(.opacity)
                }
                ForEach(Array(manager.items.enumerated()), id: \.element.id) { index, item in
                    let x = ClotheslineLayout.x(index: index, count: manager.items.count, width: width)
                    let ropeY = ClotheslineLayout.ropeY(x: x, width: width)
                    PeggedPhotoView(item: item, manager: manager, menuProvider: menuProvider)
                        .frame(width: ClotheslineLayout.cardWidth,
                               height: ClotheslineLayout.panelHeight - ropeY, alignment: .top)
                        .position(x: x,
                                  y: ropeY - ClotheslineLayout.pinAbove
                                    + (ClotheslineLayout.panelHeight - ropeY) / 2)
                }
            }
            .animation(.spring(response: 0.55, dampingFraction: 0.78), value: manager.items.map(\.id))
            .animation(.easeInOut(duration: 0.3), value: manager.items.isEmpty)
            .offset(y: manager.revealed ? 0 : -(ClotheslineLayout.panelHeight + 12))
            .animation(manager.revealed ? .spring(response: 0.42, dampingFraction: 0.82)
                                        : .easeIn(duration: 0.22), value: manager.revealed)
        }
        .onPreferenceChange(HitRectsKey.self) { manager.hitRects = $0 }
    }
}

// MARK: - 单张照片

/// 照片 + 衣夹。挂上摆动、微风摆动、按压缩放、悬停显角标。
struct PeggedPhotoView: View {
    let item: PeggedPhoto
    @ObservedObject var manager: ClotheslineManager
    var menuProvider: ((PeggedPhoto) -> NSMenu)? = nil

    @State private var swing: Double = 0
    @State private var arrived = false
    @State private var hovering = false

    private var copied: Bool { manager.copiedID == item.id }
    private var dragging: Bool { manager.draggingID == item.id }
    private var pressed: Bool { manager.pressedID == item.id }

    /// 照片在卡内适配保持纵横比。
    static func photoSize(for size: CGSize) -> CGSize {
        let maxW = ClotheslineLayout.cardWidth - 14, maxH: CGFloat = 104
        guard size.width > 0, size.height > 0 else { return CGSize(width: maxW, height: maxH) }
        let scale = min(maxW / size.width, maxH / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// 卡片尺寸 = 照片 + 玻璃内衬。
    static func cardSize(for size: CGSize) -> CGSize {
        let p = photoSize(for: size)
        return CGSize(width: p.width + 8, height: p.height + 8)
    }

    /// 挂件顶（衣夹）到卡片顶的距离。
    static let cardOffsetBelowTop: CGFloat = 14

    var body: some View {
        VStack(spacing: -12) {
            Clothespin()
                .zIndex(1)
            card
        }
        .rotationEffect(.degrees(swing + item.tilt), anchor: .top)
        .offset(y: arrived ? 0 : -46)
        // 掉落动画由全屏动画窗接管；此处即时让位。
        .opacity(item.falling || item.flying ? 0 : (arrived ? 1 : 0))
        .transaction { t in if item.falling { t.animation = nil } }
        .animation(.easeOut(duration: 0.16), value: item.flying)
        .onAppear(perform: arrive)
        .onChange(of: item.flying) { was, now in if was && !now { nudge(2.2) } }
        .onChange(of: manager.gust) { _, _ in breeze() }
        .onChange(of: copied) { _, isCopied in if isCopied { nudge(3) } }
    }

    private var card: some View {
        Image(nsImage: item.thumb)
            .resizable()
            .interpolation(.high)
            .frame(width: Self.photoSize(for: item.thumb.size).width,
                   height: Self.photoSize(for: item.thumb.size).height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            .padding(4)
            .glassCard()
            .shadow(color: .black.opacity(hovering ? 0.26 : 0.18),
                    radius: hovering ? 14 : 10, y: hovering ? 8 : 5)
            // 按住缓慢压缩：长按在蓄力。
            .scaleEffect(pressed ? 0.95 : (hovering ? 1.035 : 1), anchor: .top)
            .animation(pressed ? .easeInOut(duration: 0.45) : .spring(response: 0.3, dampingFraction: 0.6),
                       value: pressed)
            .opacity(dragging ? 0.45 : 1)
            .overlay(alignment: .topLeading) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 20, height: 20)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(3)
                    .opacity(hovering && !dragging ? 1 : 0)
                    .scaleEffect(hovering ? 1 : 0.6)
                    .allowsHitTesting(false)
            }
            .overlay(GrabArea(item: item, manager: manager, menuProvider: menuProvider))
            .overlay(alignment: .bottom) {
                if copied {
                    Label(manager.copiedLabel, systemImage: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .offset(y: 16)
                        .transition(.opacity.combined(with: .offset(y: -4)))
                }
            }
            .animation(.easeOut(duration: 0.18), value: hovering)
            .animation(.easeOut(duration: 0.2), value: copied)
            .onHover { hovering = $0 }
            .background(
                GeometryReader { g in
                    Color.clear.preference(
                        key: HitRectsKey.self,
                        value: item.falling ? [:] : [item.id: g.frame(in: .global)])
                })
    }

    private func arrive() {
        if item.flying { arrived = true; return }
        swing = 16
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) { arrived = true }
        withAnimation(.interpolatingSpring(stiffness: 46, damping: 2.6)) { swing = 0 }
    }

    private func breeze() {
        let delay = Double.random(in: 0...0.35)
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            nudge(Double.random(in: 1.6...3.4))
        }
    }

    private func nudge(_ degrees: Double) {
        withAnimation(.easeOut(duration: 0.3)) { swing = degrees }
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            withAnimation(.interpolatingSpring(stiffness: 38, damping: 2.4)) { swing = 0 }
        }
    }
}

// MARK: - 材质与衣夹

extension View {
    /// 简洁玻璃卡：模糊材质 + 上亮下暗双向描边。
    func glassCard() -> some View {
        background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0.12)],
                                           startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.black.opacity(0.10), lineWidth: 0.5).padding(-0.5))
    }
}

/// 铝制小衣夹：拉丝金属条 + 夹线槽 + 投影。
private struct Clothespin: View {
    private let metal = LinearGradient(
        stops: [
            .init(color: Color(white: 0.70), location: 0),
            .init(color: Color(white: 0.93), location: 0.35),
            .init(color: Color(white: 0.82), location: 0.65),
            .init(color: Color(white: 0.62), location: 1),
        ], startPoint: .leading, endPoint: .trailing)

    var body: some View {
        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
            .fill(metal)
            .frame(width: 9, height: 26)
            .overlay(
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .stroke(LinearGradient(colors: [Color.white.opacity(0.9), Color.black.opacity(0.18)],
                                           startPoint: .top, endPoint: .bottom), lineWidth: 0.6))
            .overlay(alignment: .top) {
                Capsule().fill(Color.black.opacity(0.32))
                    .frame(width: 5, height: 1.4)
                    .padding(.top, 8.5)
            }
            .shadow(color: .black.opacity(0.30), radius: 2, y: 1.5)
            .allowsHitTesting(false)
    }
}
