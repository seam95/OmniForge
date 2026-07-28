import CoreGraphics

/// 向上回溯结果。
struct AncestorSnapResult: Equatable {
    let rect: CGRect
    /// 是否为窗口根兜底(供调试/日志区分)。
    let isWindowFallback: Bool
}

/// AX 元素向上回溯纯函数:从命中元素沿 parent 链找第一个 frame 达标的祖先;
/// 全部不达标时回退到窗口根(role == kAXWindowRole)。
enum AXSnapAncestor {
    /// - Parameters:
    ///   - element: 起始元素。
    ///   - minSize: 最小边长阈值(pt)。
    ///   - frameReader: 读元素 frame。
    ///   - roleReader: 读元素 role。
    ///   - parentReader: 读元素 parent。
    /// - Returns: 达标 frame 或窗口根兜底;均无则 nil。
    static func smallestSnapAncestor<Element>(
        of element: Element,
        minSize: CGFloat,
        frameReader: (Element) -> CGRect?,
        roleReader: (Element) -> String?,
        parentReader: (Element) -> Element?
    ) -> AncestorSnapResult? {
        var current: Element? = element
        var windowRootFrame: CGRect?
        let maxDepth = 20  // 深度上限,防异常循环

        for _ in 0..<maxDepth {
            guard let node = current else { break }
            let role = roleReader(node)
            let frame = frameReader(node)

            // 记录首次遇到的窗口根 frame
            if windowRootFrame == nil, role == "AXWindow", let f = frame {
                windowRootFrame = f
            }
            // 达标且非窗口根 → 提前返回。
            // 窗口根(role == AXWindow)只作为兜底:即使尺寸达标也不在此命中,
            // 统一交由尾部兜底逻辑返回 isWindowFallback: true,
            // 以区分"命中中间祖先"与"回退到窗口根"两种语义。
            if role != "AXWindow", let frame, frame.width >= minSize, frame.height >= minSize {
                return AncestorSnapResult(rect: frame, isWindowFallback: false)
            }
            current = parentReader(node)
        }

        // 兜底:窗口根 frame 也达标才用
        if let root = windowRootFrame, root.width >= minSize, root.height >= minSize {
            return AncestorSnapResult(rect: root, isWindowFallback: true)
        }
        return nil
    }
}
