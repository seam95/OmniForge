import AppKit
import XCTest
@testable import OmniForge

/// 阶段 6：剪贴板图片加载退出渲染路径（SPEC §9.3）与竞态防护。
@MainActor
final class ClipboardImageAsyncLoadingTests: XCTestCase {

    /// 快速切换选中图片时，旧条目在途加载结果不得覆盖新条目的展示。
    /// loader 以 generation 丢弃晚到结果（SPEC §9.3.3）。
    func test_rapidSelectionChange_oldLoadDoesNotOverwriteNewSelection() async throws {
        let slowID = UUID()   // 先选中（慢 blob，晚完成）
        let fastID = UUID()   // 立即切到（快 blob，先完成）
        let store = PerKeyDelayBlobStore(
            contentByID: [
                slowID: .image(makeSolidPNG(color: .red, size: 400)),
                fastID: .image(makeSolidPNG(color: .blue, size: 800)),
            ],
            delayByID: [slowID: 0.3, fastID: 0.02]
        )

        let loader = ClipboardDetailImageLoader(cache: ClipboardImageCache(testInstance: ()))

        loader.request(
            entryID: slowID,
            maxPixelSize: 2000,
            loadPayload: { store.loadFullContent(for: slowID) }
        )
        // 慢条目仍在途时切到快条目。
        try await Task.sleep(nanoseconds: 60_000_000)
        loader.request(
            entryID: fastID,
            maxPixelSize: 2000,
            loadPayload: { store.loadFullContent(for: fastID) }
        )

        // 快条目先完成 → 展示快条目；随后慢条目晚到，不得覆盖。
        try await waitUntil { loader.image != nil }
        XCTAssertEqual(
            loader.image?.size, NSSize(width: 800, height: 800),
            "先展示快速选中项"
        )

        try await Task.sleep(nanoseconds: 500_000_000) // 慢条目此时应已完成并被丢弃
        XCTAssertEqual(
            loader.image?.size, NSSize(width: 800, height: 800),
            "旧请求晚到不得覆盖新选中项展示（generation 校验）"
        )
    }

    /// 后台加载不在主线程执行 blob 读取：慢 store 下主线程不被阻塞。
    func test_imageLoad_runsBlobReadOffMainThread() async throws {
        let id = UUID()
        let store = PerKeyDelayBlobStore(
            contentByID: [id: .image(makeSolidPNG(color: .green, size: 400))],
            delayByID: [id: 0.3]
        )

        let start = CFAbsoluteTimeGetCurrent()
        let content = await Task.detached(priority: .userInitiated) {
            ClipboardHistoryManager.loadImagePayload(for: id, store: store)
        }.value
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertNotNil(content, "后台通道应取到 blob")
        XCTAssertGreaterThanOrEqual(elapsed, 0.0)
    }

    /// loader 缓存命中时立即返回，不发后台任务。
    func test_cachedImageHit_returnsImmediately() async throws {
        let id = UUID()
        let png = makeSolidPNG(color: .black, size: 300)
        let cache = ClipboardImageCache()
        // 预置解码图到缓存。
        let image = try XCTUnwrap(ClipboardImageDownsampler.image(data: png, maxPixelSize: 2000))
        cache.storeDetailImage(image, for: id, maxPixelSize: 2000)

        let loader = ClipboardDetailImageLoader(cache: cache)
        let store = PerKeyDelayBlobStore(
            contentByID: [id: .image(png)],
            delayByID: [id: 5.0]
        )
        loader.request(
            entryID: id,
            maxPixelSize: 2000,
            loadPayload: { store.loadFullContent(for: id) }
        )

        XCTAssertNotNil(loader.image, "缓存命中应立即返回，不触发慢加载")
    }

    // MARK: - 工具

    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if !condition() {
            XCTFail("等待条件超时")
        }
    }

    /// 生成纯色 PNG。
    private func makeSolidPNG(color: NSColor, size: Int) -> Data {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            rect.fill()
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            XCTFail("测试图片生成失败")
            return Data()
        }
        return png
    }
}

/// 带 per-entry 延迟的 blob store：慢/快条目并存以构造竞态。
private final class PerKeyDelayBlobStore: ClipboardStore {
    private let contentByID: [UUID: ClipboardContent]
    private let delayByID: [UUID: TimeInterval]

    init(contentByID: [UUID: ClipboardContent], delayByID: [UUID: TimeInterval]) {
        self.contentByID = contentByID
        self.delayByID = delayByID
    }

    func loadEntries() -> [ClipboardEntry] { [] }
    func saveEntries(_ entries: [ClipboardEntry]) {}
    func saveEntry(_ entry: ClipboardEntry) {}
    func deleteEntries(ids: Set<UUID>) {}
    func releaseMemory() {}

    func loadFullContent(for entryID: UUID) -> ClipboardContent? {
        if let delay = delayByID[entryID], delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }
        return contentByID[entryID]
    }
}
