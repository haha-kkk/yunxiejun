import Foundation

enum VocabularySource: String, Sendable, CaseIterable {
    case manual
    // 表示已经确认加入的自动词条。三次计数和确认流程由 T20/T21 负责。
    case automatic
}

struct VocabularyTerm: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    let source: VocabularySource
    let createdAt: Date
    let updatedAt: Date
}

enum VocabularyFailure: Error, Equatable {
    case invalidText, duplicate, notFound, closed, invalidLocation, storageUnavailable
    case incompatibleDatabase, newerSchema(Int), invalidData, changedSinceEditing
    case sqlite(Int32)

    var message: String {
        switch self {
        case .invalidText: return "词条不能为空，也不能包含换行或控制字符。"
        case .duplicate: return "词典中已有这个词条。"
        case .notFound: return "词条不存在或已删除，请刷新词典。"
        case .closed: return "词典连接已关闭，请重新打开。"
        case .invalidLocation: return "词典必须保存在本机有效的文件路径。"
        case .storageUnavailable: return "无法创建词典存储目录，请检查访问权限。"
        case .incompatibleDatabase: return "这个文件不是本应用支持的词典，原文件未被重建。"
        case .newerSchema: return "词典来自更新版本，请使用对应版本的应用打开。"
        case .invalidData: return "词典数据格式异常，原数据未被重建。"
        case .changedSinceEditing: return "这个词条已经发生变化，本次操作未执行。请刷新词典后重新操作。"
        case .sqlite(let code): return "词典读写失败（代码 \(code)），请稍后重试。"
        }
    }
}

/// 只在本次应用运行中保留一步撤销，不保存 API 密钥或历史操作栈。
struct VocabularyUndo: Equatable, Sendable {
    let before: VocabularyTerm?
    let after: VocabularyTerm
    let deleted: Bool

    var title: String { deleted ? "撤销删除" : (before == nil ? "撤销添加" : "撤销编辑") }
}

enum VocabularyEdit: Sendable {
    case add(String)
    case update(VocabularyTerm, String)
    case delete(VocabularyTerm)
    case undo(VocabularyUndo)
}

struct VocabularyEditResult: Sendable {
    let affectedID: UUID
    let term: VocabularyTerm?
    let undo: VocabularyUndo?
}
