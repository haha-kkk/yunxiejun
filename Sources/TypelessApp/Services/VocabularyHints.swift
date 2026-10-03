import Foundation

/// 未注入正式词典的隔离测试沿用空词表，不隐式打开用户数据库。
struct EmptyVocabularyListing: VocabularyListing {
    func list() async throws -> [VocabularyTerm] { [] }
}

enum VocabularyHintsFailure: Error, Equatable {
    case tooLarge
    var message: String { "本次参考词典超过 8 KB，请精简词条后重试；没有截断词条或发送请求。" }
}

/// 每次调用读取正式词典，不使用设置页筛选结果或未确认候选。
/// 请求开始时取快照，正在发送的请求不随之后的编辑改变。
struct VocabularyHints: Sendable {
    static let maximumBytes = 8_192
    let terms: [String]

    init(terms: [VocabularyTerm]) throws {
        var seen = Set<String>()
        var values: [String] = []
        for term in terms {
            let text = try VocabularyStore.validatedText(term.text)
            if seen.insert(VocabularyStore.key(text)).inserted { values.append(text) }
        }
        guard try JSONEncoder().encode(values).count <= Self.maximumBytes else {
            throw VocabularyHintsFailure.tooLarge
        }
        self.terms = values
    }

    static func load(from source: any VocabularyListing) async throws -> Self {
        try Task.checkCancellation()
        let terms = try await source.list()
        try Task.checkCancellation()
        return try Self(terms: terms)
    }

    func speechContext() throws -> String? {
        guard !terms.isEmpty else { return nil }
        // ASR 的 system 只支持参考上下文，不是角色提示；不传强制替换映射。
        let data = try JSONEncoder().encode(["实体词表": terms])
        return String(decoding: data, as: UTF8.self)
    }
}
