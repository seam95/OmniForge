import XCTest
@testable import OmniForge

/// 阶段 6 美化层测试，覆盖 BeautifyRenderer/BeautifyPreset 的关键能力。
final class BeautifyRendererTests: XCTestCase {

    private func makeImage(_ size: NSSize, color: NSColor = .red) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocusFlipped(false)
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    // MARK: - 几何

    func test_padding_clampsToRange() {
        let tiny = BeautifyRenderer.padding(for: NSSize(width: 1, height: 1))
        XCTAssertEqual(tiny, BeautifyRenderer.paddingMin)
        let huge = BeautifyRenderer.padding(for: NSSize(width: 100_000, height: 100_000))
        XCTAssertEqual(huge, BeautifyRenderer.paddingMax)
    }

    func test_outputSize_addsPaddingOnBothSides() {
        let inner = NSSize(width: 100, height: 80)
        let p = BeautifyRenderer.padding(for: inner)
        let outer = BeautifyRenderer.outputSize(for: inner)
        XCTAssertEqual(outer.width, inner.width + 2 * p, accuracy: 0.001)
        XCTAssertEqual(outer.height, inner.height + 2 * p, accuracy: 0.001)
    }

    func test_innerRect_offsetByPadding() {
        let inner = NSSize(width: 100, height: 80)
        let p = BeautifyRenderer.padding(for: inner)
        let rect = BeautifyRenderer.innerRect(for: inner)
        XCTAssertEqual(rect.origin.x, p, accuracy: 0.001)
        XCTAssertEqual(rect.origin.y, p, accuracy: 0.001)
        XCTAssertEqual(rect.width, inner.width, accuracy: 0.001)
        XCTAssertEqual(rect.height, inner.height, accuracy: 0.001)
    }

    // MARK: - render

    func test_render_returnsLargerImageWithPadding() {
        let inner = makeImage(NSSize(width: 100, height: 80))
        let result = BeautifyRenderer.render(innerImage: inner, preset: .defaultPreset)
        let p = BeautifyRenderer.padding(for: inner.size)
        XCTAssertEqual(result.size.width, 100 + 2 * p, accuracy: 0.5)
        XCTAssertEqual(result.size.height, 80 + 2 * p, accuracy: 0.5)
    }

    func test_render_preservesBackingScale() {
        // 带 2x 像素表示的内图，render 后位图表示应保持高像素密度。
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 200, pixelsHigh: 160,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32
        )!
        rep.size = NSSize(width: 100, height: 80)
        let inner = NSImage(size: NSSize(width: 100, height: 80))
        inner.addRepresentation(rep)

        let result = BeautifyRenderer.render(innerImage: inner, preset: .defaultPreset)
        let resultRep = result.representations.first as? NSBitmapImageRep
        XCTAssertNotNil(resultRep)
        // 像素宽应 ≥ 200（内图 100 点 × 2，再加 padding 像素）。
        XCTAssertGreaterThanOrEqual(resultRep!.pixelsWide, 200)
    }

    func test_render_zeroSize_returnsInputUnchanged() {
        let inner = NSImage(size: .zero)
        let result = BeautifyRenderer.render(innerImage: inner, preset: .defaultPreset)
        XCTAssertTrue(result === inner)
    }

    func test_render_hasAlphaForTransparentBackground() {
        // 渐变背景的 alpha 为 1，但结果图像本身应支持 alpha 通道（圆角外透明）。
        let inner = makeImage(NSSize(width: 50, height: 50))
        let result = BeautifyRenderer.render(innerImage: inner, preset: .defaultPreset)
        guard let rep = result.representations.first as? NSBitmapImageRep else {
            return XCTFail("expected bitmap rep")
        }
        // hasAlpha 为 true 即可表明 alpha 通道存在。
        XCTAssertEqual(rep.samplesPerPixel, 4)
    }

    // MARK: - BeautifyPreset

    func test_preset_defaultsContainsWallpaperAndGradients() {
        XCTAssertTrue(BeautifyPreset.defaults.contains { $0.isWallpaper })
        XCTAssertEqual(BeautifyPreset.defaults.count, 9)
    }

    func test_preset_forID_returnsMatching() {
        let preset = BeautifyPreset.preset(forID: "deep-purple")
        XCTAssertNotNil(preset)
        XCTAssertEqual(preset?.id, "deep-purple")
    }

    func test_preset_defaultPreset_isFirstGradient() {
        XCTAssertEqual(BeautifyPreset.defaultPreset.id, "peach-blue")
    }

    func test_preset_wallpaper_isClearColors() {
        XCTAssertEqual(BeautifyPreset.wallpaper.startColor, .clear)
        XCTAssertTrue(BeautifyPreset.wallpaper.isWallpaper)
    }

    // MARK: - 双层阴影渲染不崩溃（像素级正确性需真机/位图采样，这里验证可渲染）

    func test_render_withShadowEnabled_doesNotCrash() {
        let inner = makeImage(NSSize(width: 60, height: 60))
        _ = BeautifyRenderer.render(innerImage: inner, preset: .defaultPreset, shadowEnabled: true)
        _ = BeautifyRenderer.render(innerImage: inner, preset: .defaultPreset, shadowEnabled: false)
        // 能渲染完成即通过。
    }
}
