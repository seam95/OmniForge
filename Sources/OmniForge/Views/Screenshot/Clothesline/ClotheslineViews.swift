import SwiftUI

/// Task 9 前的最小视图占位：协调器只引用这三个符号，
/// 本文件仅保证编译通过，Task 9 整文件替换为真实绳视图。

struct ClotheslineView: View {
    @ObservedObject var manager: ClotheslineManager
    var body: some View { Color.clear }
}

final class PeggedPhotoView: NSView {}

extension PeggedPhotoView {
    /// 占位卡片尺寸；真实的按纵横比等比计算在 Task 9 落地。
    static func cardSize(for size: CGSize) -> CGSize { CGSize(width: 150, height: 112) }
}

final class GrabPhotoView: NSView {
    /// 拖拽进行中标志：显隐状态机据此判定「忙碌不收绳」。
    static var isDragging = false
}
