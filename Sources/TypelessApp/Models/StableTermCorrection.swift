import Foundation
import NaturalLanguage

/// 保守地提取一个短词语替换；不把整段改写、纯插入/删除或标点变化当作术语。
enum TermReplacement {
    static func extract(before: String, after: String) -> (String, String)? {
        tokenizedReplacement(before: before, after: after)
            ?? spacingTolerantReplacement(before: before, after: after)
    }

    private static func tokenizedReplacement(before: String, after: String) -> (String, String)? {
        func words(_ text: String) -> [Range<String.Index>] {
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = text
            return tokenizer.tokens(for: text.startIndex..<text.endIndex)
        }
        let old = words(before), new = words(after)
        var prefix = 0, suffix = 0
        while prefix < min(old.count, new.count), before[old[prefix]] == after[new[prefix]] { prefix += 1 }
        while suffix < min(old.count, new.count) - prefix,
              before[old[old.count - 1 - suffix]] == after[new[new.count - 1 - suffix]] { suffix += 1 }
        let oldEnd = old.count - suffix, newEnd = new.count - suffix
        guard prefix < oldEnd, prefix < newEnd, oldEnd - prefix <= 3, newEnd - prefix <= 3 else { return nil }
        let oldRange = old[prefix].lowerBound..<old[oldEnd - 1].upperBound
        let newRange = new[prefix].lowerBound..<new[newEnd - 1].upperBound
        guard before[..<oldRange.lowerBound] == after[..<newRange.lowerBound],
              before[oldRange.upperBound...] == after[newRange.upperBound...] else { return nil }
        let oldWords = Set(old[prefix..<oldEnd].map { String(before[$0]) })
        guard !new[prefix..<newEnd].contains(where: { oldWords.contains(String(after[$0])) }) else { return nil }
        let original = String(before[oldRange]), corrected = String(after[newRange])
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_+.#"))
        guard [original, corrected].allSatisfy({ !$0.isEmpty && $0.count <= 80 && $0.unicodeScalars.allSatisfy(allowed.contains) }),
              original != corrected else { return nil }
        return (original, corrected)
    }

    /// TextEdit 在替换中英混排词时可能顺手移除词两侧空格。
    /// 只允许一次连续替换及紧邻空格变化；句中其他字符仍必须完全相同。
    private static func spacingTolerantReplacement(before: String, after: String) -> (String, String)? {
        let old = Array(before), new = Array(after)
        var start = 0
        while start < min(old.count, new.count), old[start] == new[start] { start += 1 }
        var end = 0
        while end < min(old.count, new.count) - start,
              old[old.count - 1 - end] == new[new.count - 1 - end] { end += 1 }
        let oldDiff = Array(old[start..<(old.count - end)])
        let newDiff = Array(new[start..<(new.count - end)])
        let trim = CharacterSet(charactersIn: " \t")
        let original = String(oldDiff).trimmingCharacters(in: trim)
        let corrected = String(newDiff).trimmingCharacters(in: trim)
        let movedAdjacentSpace = oldDiff.first.map({ $0 == " " || $0 == "\t" }) == true
            || oldDiff.last.map({ $0 == " " || $0 == "\t" }) == true
            || newDiff.first.map({ $0 == " " || $0 == "\t" }) == true
            || newDiff.last.map({ $0 == " " || $0 == "\t" }) == true
        guard !original.isEmpty, !corrected.isEmpty, original != corrected,
              movedAdjacentSpace, !original.contains(where: { $0 == " " || $0 == "\t" }),
              !corrected.contains(where: { $0 == " " || $0 == "\t" }),
              original.count <= 80, corrected.count <= 80,
              oldDiff.first.map({ !$0.isLetter && !$0.isNumber }) == true || start == 0 || !old[start - 1].isLetter && !old[start - 1].isNumber,
              oldDiff.last.map({ !$0.isLetter && !$0.isNumber }) == true || end == 0 || !old[old.count - end].isLetter && !old[old.count - end].isNumber else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_+.#"))
        guard [original, corrected].allSatisfy({ $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return nil }
        let tokenizer = NLTokenizer(unit: .word)
        for word in [original, corrected] {
            tokenizer.string = word
            guard tokenizer.tokens(for: word.startIndex..<word.endIndex).count <= 3 else { return nil }
        }
        return (original, corrected)
    }
}

/// 一次手动验证对应一次输出观察；稳定一秒后提取，最多发出一个事件。
struct StableTermCorrection {
    private var sessionID = UUID()
    private var eventID = UUID()
    private var baseline: ExternalTextSnapshot?
    private var latest: ExternalTextSnapshot?
    private var changedAt: TimeInterval = 0
    private var emitted = false
    let settleSeconds: TimeInterval

    init(settleSeconds: TimeInterval = 1) { self.settleSeconds = settleSeconds }

    mutating func begin(baseline: ExternalTextSnapshot? = nil) {
        sessionID = UUID(); eventID = UUID(); emitted = false
        breakContinuity()
        self.baseline = baseline
    }

    mutating func breakContinuity() { baseline = nil; latest = nil }

    mutating func receive(_ sample: ExternalTextSnapshot, now: TimeInterval) -> TermCorrection? {
        guard !emitted else { return nil }
        if let reference = latest ?? baseline,
           reference.targetPID != sample.targetPID || reference.fieldID != sample.fieldID { breakContinuity() }
        guard latest == sample else {
            latest = sample; changedAt = now
            return nil
        }
        guard now - changedAt >= settleSeconds else { return nil }
        guard let baseline else { self.baseline = sample; return nil }
        guard baseline.text != sample.text else { return nil }
        guard let (before, after) = TermReplacement.extract(before: baseline.text, after: sample.text) else { return nil }
        emitted = true
        return TermCorrection(id: eventID, sessionID: sessionID, observedText: before, correctedText: after)
    }
}
