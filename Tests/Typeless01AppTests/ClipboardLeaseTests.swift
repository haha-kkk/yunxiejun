import AppKit
import Testing
@testable import Typeless01App

@MainActor
private final class FakeClipboard: ClipboardAccess {
    var changeCount = 0
    var items: [[String: Data]] = []
    var replacements = 0
    var failSnapshot = false
    var changeDuringSnapshot = false
    var failWrite = false
    func snapshotItems() throws -> [[String: Data]] {
        if failSnapshot { throw TextOutputFailure.unavailable }
        if changeDuringSnapshot { changeCount += 1 }
        return items
    }
    func replaceItems(_ items: [[String: Data]]) -> Bool {
        if failWrite { return false }
        self.items = items; changeCount += 1; replacements += 1
        return true
    }
}

@Suite("临时剪贴板保护")
@MainActor
struct ClipboardLeaseTests {
    @Test("恢复多条目与全部数据类型，不仅纯文本")
    func restoresEveryRepresentation() throws {
        let board = FakeClipboard()
        let original = [["public.utf8-plain-text": Data("原文".utf8), "public.rtf": Data([1, 2, 3])],
                        ["public.png": Data([0, 1, 0, 255])]]
        board.items = original
        let lease = try ClipboardLease(board: board, text: "测试")
        #expect(lease.ownsClipboard)
        #expect(board.items != original)
        lease.restoreIfOwned()
        #expect(board.items == original)
        lease.restoreIfOwned()
        #expect(board.replacements == 2)
    }
    @Test("用户或其他程序更新剪贴板后绝不覆盖")
    func leavesExternalChangeAlone() throws {
        let board = FakeClipboard()
        let lease = try ClipboardLease(board: board, text: "测试")
        let newer = [["public.utf8-plain-text": Data("用户后来复制".utf8)]]
        _ = board.replaceItems(newer)
        #expect(!lease.ownsClipboard)
        lease.restoreIfOwned()
        #expect(board.items == newer)
        #expect(board.replacements == 2)
    }
    @Test("无法完整备份时不修改剪贴板")
    func rejectsIncompleteSnapshot() {
        let board = FakeClipboard(); board.failSnapshot = true
        #expect(throws: TextOutputFailure.unavailable) { try ClipboardLease(board: board, text: "测试") }
        #expect(board.replacements == 0)
    }
    @Test("备份期间外部更新时拒绝写入")
    func refusesChangedSnapshot() {
        let board = FakeClipboard(); board.changeDuringSnapshot = true
        #expect(throws: TextOutputFailure.unavailable) { try ClipboardLease(board: board, text: "测试") }
        #expect(board.replacements == 0)
    }
    @Test("恢复失败返回失败，不伪称恢复成功")
    func reportsRestoreFailure() throws {
        let board = FakeClipboard()
        let lease = try ClipboardLease(board: board, text: "测试")
        board.failWrite = true
        #expect(!lease.restoreIfOwned())
    }
    @Test("空剪贴板恢复为空")
    func restoresEmptyClipboard() throws {
        let board = FakeClipboard()
        let lease = try ClipboardLease(board: board, text: "测试")
        lease.restoreIfOwned()
        #expect(board.items.isEmpty)
    }
}
