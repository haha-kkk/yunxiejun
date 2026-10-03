import AppKit

@MainActor
protocol ClipboardAccess: AnyObject {
    var changeCount: Int { get }
    func snapshotItems() throws -> [[String: Data]]
    func replaceItems(_ items: [[String: Data]]) -> Bool
}

extension NSPasteboard: ClipboardAccess {
    func snapshotItems() throws -> [[String: Data]] {
        let before = changeCount
        let result = try (pasteboardItems ?? []).map { item in
            var types: [String: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { throw TextOutputFailure.unavailable }
                types[type.rawValue] = data
            }
            return types
        }
        guard changeCount == before else { throw TextOutputFailure.unavailable }
        return result
    }

    func replaceItems(_ items: [[String: Data]]) -> Bool {
        let objects = items.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return item
        }
        clearContents()
        return objects.isEmpty || writeObjects(objects)
    }
}

/// A lease owns only its own clipboard write, never a later user/app clipboard change.
@MainActor
final class ClipboardLease<Board: ClipboardAccess> {
    private let board: Board
    private let original: [[String: Data]]
    private let writtenCount: Int
    private var restored = false
    var ownsClipboard: Bool { !restored && board.changeCount == writtenCount }

    init(board: Board, text: String) throws {
        self.board = board
        let before = board.changeCount
        original = try board.snapshotItems()
        guard board.changeCount == before else { throw TextOutputFailure.unavailable }
        guard board.replaceItems([[NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)]]) else {
            _ = board.replaceItems(original)
            throw TextOutputFailure.unavailable
        }
        writtenCount = board.changeCount
    }

    @discardableResult
    func restoreIfOwned() -> Bool {
        guard ownsClipboard else { return true }
        restored = true
        return board.replaceItems(original)
    }
}
