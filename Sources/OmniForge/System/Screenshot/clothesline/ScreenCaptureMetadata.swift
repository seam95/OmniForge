// Sources/OmniForge/System/Screenshot/clothesline/ScreenCaptureMetadata.swift
import AppKit
import Foundation

/// 读取系统截图服务写在截图文件上的扩展属性。
/// 判定「是否系统截图」与「截取时的全屏区域矩形」两件事。
enum ScreenCaptureMetadata {
    private static let isScreenCaptureXattr = "com.apple.metadata:kMDItemIsScreenCapture"
    private static let globalRectXattr = "com.apple.metadata:kMDItemScreenCaptureGlobalRect"

    /// 是否带系统截图标记（自家保存的文件不带，天然区分来源）。
    static func isScreenCapture(_ url: URL) -> Bool {
        readXattr(url, name: isScreenCaptureXattr) != nil
    }

    /// 截取区域（AppKit 屏幕坐标）。无属性或形状异常返回 nil。
    /// - Parameter mainScreenMaxY: 主屏 frame.maxY（全局坐标以主屏左上为原点，需翻转）。
    static func captureGlobalRect(_ url: URL, mainScreenMaxY: CGFloat) -> NSRect? {
        guard let data = readXattr(url, name: globalRectXattr),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [NSNumber],
              values.count == 4
        else { return nil }
        let x = CGFloat(truncating: values[0]), y = CGFloat(truncating: values[1])
        let w = CGFloat(truncating: values[2]), h = CGFloat(truncating: values[3])
        guard w > 2, h > 2 else { return nil }
        return appKitRect(x: x, y: y, w: w, h: h, mainScreenMaxY: mainScreenMaxY)
    }

    /// 全局（主屏左上原点）→ AppKit（左下原点）坐标转换，纯函数。
    static func appKitRect(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, mainScreenMaxY: CGFloat) -> NSRect {
        NSRect(x: x, y: mainScreenMaxY - y - h, width: w, height: h)
    }

    private static func readXattr(_ url: URL, name: String) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let size = getxattr(path, name, nil, 0, 0, 0)
            guard size > 0 else { return nil }
            var buffer = Data(count: size)
            let read = buffer.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
            return read == size ? buffer : nil
        }
    }
}
