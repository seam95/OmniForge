import XCTest
@testable import OmniForge

/// 阶段 2 画布交互层重写后的契约测试，聚焦 AnnotationDocument 的
/// 三段式 undo/redo 与橡皮擦连续删除合并逻辑（参照 capcap EditorSnapshot）。
///
/// 注意：Document 的 `append`/`replace`/`remove` **不自动 recordUndo**，
/// 调用方（画布交互层）负责在瞬时变更前显式调 `recordUndo()`——这与
/// capcap 一致（`EditCanvasView` 在 mouseUp 各工具 commit 时显式 record）。
@MainActor
final class AnnotationDocumentTests: XCTestCase {

    private func makeRect(_ origin: CGPoint = .zero) -> RectAnnotation {
        RectAnnotation(rect: NSRect(x: origin.x, y: origin.y, width: 50, height: 50))
    }

    // MARK: - 基础 add / undo / redo（显式 recordUndo）

    func test_recordUndo_enablesUndoAndClearsRedo() {
        let doc = AnnotationDocument()
        XCTAssertFalse(doc.canUndo)
        XCTAssertFalse(doc.canRedo)

        doc.recordUndo()
        doc.append(makeRect())
        XCTAssertTrue(doc.canUndo)
        XCTAssertFalse(doc.canRedo)
    }

    func test_undo_revertsToBeforeLastRecordedChange() {
        let doc = AnnotationDocument()
        doc.recordUndo(); doc.append(makeRect())
        doc.recordUndo(); doc.append(makeRect(CGPoint(x: 100, y: 0)))
        XCTAssertEqual(doc.annotations.count, 2)

        XCTAssertTrue(doc.undo())
        XCTAssertEqual(doc.annotations.count, 1)

        XCTAssertTrue(doc.undo())
        XCTAssertEqual(doc.annotations.count, 0)

        // 栈空时 undo 返回 false。
        XCTAssertFalse(doc.undo())
    }

    func test_redo_reapplies() {
        let doc = AnnotationDocument()
        doc.recordUndo(); doc.append(makeRect())
        _ = doc.undo()
        XCTAssertEqual(doc.annotations.count, 0)

        XCTAssertTrue(doc.redo())
        XCTAssertEqual(doc.annotations.count, 1)
        XCTAssertFalse(doc.canRedo)
    }

    func test_newActionAfterUndo_clearsRedoStack() {
        let doc = AnnotationDocument()
        doc.recordUndo(); doc.append(makeRect())
        doc.recordUndo(); doc.append(makeRect(CGPoint(x: 100, y: 0)))
        _ = doc.undo() // redo 栈有 1 项
        XCTAssertTrue(doc.canRedo)

        // 新增动作应清空 redo。
        doc.recordUndo(); doc.append(makeRect(CGPoint(x: 200, y: 0)))
        XCTAssertFalse(doc.canRedo)
    }

    // MARK: - 三段式 pending undo

    func test_pendingUndo_captureCommitPersistsSnapshot() {
        let doc = AnnotationDocument()
        doc.recordUndo(); doc.append(makeRect())

        // 模拟拖拽：先 capture，中途 replace 多次，最后 commit。
        doc.captureUndoForPending()
        let moved = (doc.annotations[0].annotation as! RectAnnotation)
            .withRect(NSRect(x: 10, y: 10, width: 50, height: 50))
        doc.replace(at: 0, with: moved)
        doc.replace(at: 0, with: moved.withRect(NSRect(x: 20, y: 20, width: 50, height: 50)))
        doc.commitPendingUndo()

        XCTAssertTrue(doc.canUndo)
        _ = doc.undo()
        // undo 后恢复到拖拽开始前（rect 在原点）。
        let restored = doc.annotations[0].annotation as! RectAnnotation
        XCTAssertEqual(restored.rect.origin, .zero)
    }

    func test_pendingUndo_discardDropsSnapshot() {
        let doc = AnnotationDocument()
        doc.recordUndo(); doc.append(makeRect())
        let baselineCanUndo = doc.canUndo
        XCTAssertTrue(baselineCanUndo)

        doc.captureUndoForPending()
        doc.discardPendingUndo()

        // discard 后 undo 栈与 capture 前一致（不多不少）。
        XCTAssertEqual(doc.canUndo, baselineCanUndo)
    }

    // MARK: - 橡皮擦连续删除合并

    func test_eraserBatch_mergesIntoSingleUndoStep() {
        let doc = AnnotationDocument()
        doc.recordUndo(); doc.append(makeRect())
        doc.recordUndo(); doc.append(makeRect(CGPoint(x: 100, y: 0)))
        doc.recordUndo(); doc.append(makeRect(CGPoint(x: 200, y: 0)))
        XCTAssertEqual(doc.annotations.count, 3)

        // 模拟橡皮擦：capture 一次，连续删多个，commit 一次。
        doc.captureUndoForPending()
        // 删除第 0、1 个（一次提交所有要删的索引更贴近实际框选删除）。
        doc.removeAnnotationsAtIndicesPreservingHistory([0, 1])
        doc.commitPendingUndo()

        XCTAssertEqual(doc.annotations.count, 1)

        // 一次 undo 应回到删除前（3 个）。
        _ = doc.undo()
        XCTAssertEqual(doc.annotations.count, 3)
    }

    // MARK: - replace 与 history

    func test_replace_doesNotRecordUndoByItself() {
        // replace 依赖外层的 capture/record；单独调 replace 不应压栈。
        let doc = AnnotationDocument()
        doc.recordUndo(); doc.append(makeRect())
        let undoCountBefore = doc.canUndo

        let moved = (doc.annotations[0].annotation as! RectAnnotation)
            .withRect(NSRect(x: 99, y: 0, width: 50, height: 50))
        doc.replace(at: 0, with: moved)

        // undo 可用性不变（replace 本身不记录）。
        XCTAssertEqual(doc.canUndo, undoCountBefore)
        // 但内容已更新。
        let current = doc.annotations[0].annotation as! RectAnnotation
        XCTAssertEqual(current.rect.origin.x, 99)
    }

    // MARK: - numberCounter 参与 undo/redo

    func test_numberCounter_rolledBackOnUndo() {
        let doc = AnnotationDocument()
        doc.recordUndo()
        doc.append(NumberAnnotation(center: .zero, number: 1, color: .red))
        XCTAssertEqual(doc.numberCounter, 2)

        _ = doc.undo()
        XCTAssertEqual(doc.numberCounter, 1)
    }

    // MARK: - AnyAnnotation

    func test_anyAnnotation_exposesUuid() {
        let uuid = UUID()
        let rect = RectAnnotation(uuid: uuid, rect: NSRect(x: 0, y: 0, width: 10, height: 10))
        let any = AnyAnnotation(annotation: rect)
        XCTAssertEqual(any.uuid, uuid)
    }
}
