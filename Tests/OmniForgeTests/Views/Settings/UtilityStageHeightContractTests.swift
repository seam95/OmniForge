import AppKit
import SwiftUI
import XCTest
@testable import OmniForge

/// 阶段式工具页高度契约回归测试：empty/busy/done 各阶段自然高度对齐到
/// `stageMinHeight`，阶段切换不再触发控制中心面板改高；排行页 loading 态
/// 在尺寸上下文中撑满 viewport（maxHeight: .infinity 在 ScrollView 滚动轴
/// 无限提议下会塌回内容理想高度，必须显式 minHeight）。
@MainActor
final class UtilityStageHeightContractTests: XCTestCase {
    // MARK: - 契约常量

    func test_stageMinHeight_contract() {
        XCTAssertEqual(UtilityContentLayout.compact.stageMinHeight, 420)
        XCTAssertEqual(UtilityContentLayout.settings.stageMinHeight, 480)
    }

    // MARK: - 卸载器：empty 与 scanning 同高

    func test_uninstaller_emptyAndScanning_reportSameNaturalHeight() throws {
        let emptyHeight = try measureNaturalHeight(
            UninstallerContentView(strings: .en, layout: .compact, uninstaller: AppUninstaller())
        )

        let scanner = GatedAppUninstallerScanner()
        let scanning = AppUninstaller(scanner: scanner)
        scanning.select(target: AppUninstaller.Target(
            name: "FakeApp",
            bundleID: "com.example.fakeapp",
            url: URL(fileURLWithPath: "/Applications/FakeApp.app"),
            icon: NSImage()
        ))
        XCTAssertEqual(scanning.phase, .scanning, "闸门扫描器挂起时必须停留在 scanning 态")
        let scanningHeight = try measureNaturalHeight(
            UninstallerContentView(strings: .en, layout: .compact, uninstaller: scanning)
        )
        scanner.open()

        // busy 态必须精确落在契约下限（无保底时塌缩至 ~100pt）；
        // empty 态可能因未授权机器上的完全磁盘访问提示横幅高出 ~10pt，
        // 只要求不低于契约，不要求与 busy 严格相等。
        XCTAssertEqual(scanningHeight, UtilityContentLayout.compact.stageMinHeight, accuracy: 1,
                       "scanning 自然高度必须落在契约下限（busy 无保底时会塌缩 ~100pt）")
        XCTAssertGreaterThanOrEqual(emptyHeight, UtilityContentLayout.compact.stageMinHeight,
                                    "empty 自然高度不得低于契约下限")
        XCTAssertLessThanOrEqual(emptyHeight - scanningHeight, 15,
                                 "empty 高出 busy 的部分只允许来自 FDA 提示横幅（~10pt）")
    }

    // MARK: - 完成态：与阶段契约对齐

    func test_doneView_compact_matchesStageContract() throws {
        let height = try measureNaturalHeight(
            UtilityDoneView(
                strings: .en,
                freed: 12_345_678,
                failedCount: 0,
                layout: .compact
            ) {
                EmptyView()
            }
        )
        XCTAssertEqual(height, UtilityContentLayout.compact.stageMinHeight, accuracy: 1,
                       "compact 完成态必须与 empty/busy 同高（原 320 保底会让 removing→done 跳变）")
    }

    // MARK: - 清理页：busy 与契约对齐

    func test_cleaner_busyState_matchesStageContract() throws {
        let scanner = GatedJunkScanner()
        let cleaner = JunkCleaner(scanner: scanner)
        cleaner.scan()
        XCTAssertTrue(cleaner.isBusy, "闸门扫描器挂起时必须停留在 scanning 态")

        let height = try measureNaturalHeight(
            CleanerContentView(
                strings: .en,
                layout: .compact,
                cleaner: cleaner,
                readNotificationStatus: { completion in completion(.notDetermined) }
            )
        )
        scanner.open()
        XCTAssertEqual(height, UtilityContentLayout.compact.stageMinHeight, accuracy: 1,
                       "清理 busy 态必须与 empty 同高（原 320 保底与 empty 落差 100pt+）")
    }

    // MARK: - 排行页：loading 态撑满 viewport

    func test_rankingLoading_fillsViewportWhenSizingContextPresent() throws {
        let context = ControlCenterSizingContext()
        let height = try measureNaturalHeight(
            MonitorRankingView(
                kind: .cpu,
                state: .loading(.cpu),
                strings: .en,
                onBack: {},
                onOpenSettings: {},
                onRefresh: {}
            )
            .environment(\.controlCenterSizing, context)
        )
        XCTAssertEqual(height, context.viewportHeight, accuracy: 1,
                       "尺寸上下文存在时 loading 态必须撑满 viewport，首开排行不再改高")
    }

    func test_rankingLoading_collapsesWithoutSizingContext() throws {
        // 无上下文宿主（非控制中心）保持现状：不强制最小高度。
        let height = try measureNaturalHeight(
            MonitorRankingView(
                kind: .cpu,
                state: .loading(.cpu),
                strings: .en,
                onBack: {},
                onOpenSettings: {},
                onRefresh: {}
            )
        )
        XCTAssertLessThan(height, 300, "无尺寸上下文时不得引入最小高度约束")
    }

    // MARK: - 测量 harness

    /// 复刻控制中心 sizedPanelContent 的测量方式：内容置于 ScrollView 内
    /// （滚动轴无限提议 → 自然高度），经生产同款探针上报。
    @MainActor
    private final class HeightBox: ObservableObject {
        @Published var report: CGFloat?
    }

    private func measureNaturalHeight<V: View>(_ view: V) throws -> CGFloat {
        let box = HeightBox()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: ControlCenterContentMetrics.panelWidth, height: 700),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let contentView = try XCTUnwrap(window.contentView)
        let hostingView = NSHostingView(
            rootView: ScrollView(showsIndicators: false) {
                view.modifier(ControlCenterNaturalHeightReportModifier(isEmptyState: false))
            }
            .onPreferenceChange(ControlCenterNaturalHeightKey.self) { box.report = $0?.height }
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: contentView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        hostingView.layoutSubtreeIfNeeded()
        return try XCTUnwrap(box.report, "探针未上报：内容未完成布局")
    }
}

// MARK: - 闸门扫描器（挂起保持 busy 态，测试结束放行）

private final class GatedAppUninstallerScanner: AppUninstallerScanning {
    private let gate = DispatchSemaphore(value: 0)

    func scan(target: AppUninstaller.Target) -> AppUninstaller.ScanResult {
        gate.wait(timeout: .now() + 30)
        return .init(items: [], failures: [])
    }

    func open() { gate.signal() }
}

private final class GatedJunkScanner: JunkCleanerScanning {
    private let gate = DispatchSemaphore(value: 0)

    func scan(
        progress: @escaping (CleanerScanProgress) -> Void,
        cancellation: CleanerScanCancellation
    ) throws -> JunkCleaner.ScanResult {
        gate.wait(timeout: .now() + 30)
        return .init(items: [], failures: [])
    }

    func open() { gate.signal() }
}
