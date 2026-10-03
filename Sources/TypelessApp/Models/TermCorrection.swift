import Foundation

/// 一次已确认边界的术语纠正，不是输入框的每一帧采样。
/// 调用方为同一次纠正保留同一 id，重试和重复通知必须复用它。
struct TermCorrection: Equatable, Sendable {
    let id: UUID
    let sessionID: UUID
    let observedText: String
    let correctedText: String
}

struct CorrectionCandidate: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    let count: Int64
    let updatedAt: Date
    let status: CorrectionStatus
    let decisionCount: Int64

    init(id: UUID, text: String, count: Int64, updatedAt: Date, status: CorrectionStatus = .collecting, decisionCount: Int64 = 0) {
        self.id = id; self.text = text; self.count = count; self.updatedAt = updatedAt
        self.status = status; self.decisionCount = decisionCount
    }
}

enum CorrectionStatus: String, Sendable { case collecting, pending, accepted, dismissed }
enum CorrectionDismissalPolicy: Sendable { case afterThreeNewCorrections, neverAskAgain }

struct CorrectionDecisionResult: Sendable {
    let candidate: CorrectionCandidate
    let term: VocabularyTerm?
    let undo: VocabularyUndo?
}

struct CorrectionCountResult: Equatable, Sendable {
    let candidate: CorrectionCandidate
    // false 表示同一事件已登记；返回当前累计值，不重复加一。
    let recorded: Bool
}

enum CorrectionFailure: Error, Equatable {
    case unchanged, conflictingEvent, countOverflow, notPending

    var message: String {
        switch self {
        case .unchanged: return "修改前后是同一个词，没有增加纠正次数。"
        case .conflictingEvent: return "这次纠正的编号已被另一条记录使用，没有重复计数。"
        case .countOverflow: return "纠正次数已达到存储上限，没有继续增加。"
        case .notPending: return "这条建议已处理或不再等待确认，请刷新后查看。"
        }
    }
}
