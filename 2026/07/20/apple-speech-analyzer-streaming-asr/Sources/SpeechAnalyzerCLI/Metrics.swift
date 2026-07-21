import Foundation

func normalizeJapanese(_ text: String) -> String {
    let punctuation = CharacterSet.punctuationCharacters
        .union(.whitespacesAndNewlines)
        .union(CharacterSet(charactersIn: "。、！？・「」『』（）()…〜～"))
    return text.unicodeScalars
        .filter { !punctuation.contains($0) }
        .map(String.init)
        .joined()
        .lowercased()
}

func editDistance(_ lhs: String, _ rhs: String) -> Int {
    let a = Array(lhs)
    let b = Array(rhs)
    guard !a.isEmpty else { return b.count }
    guard !b.isEmpty else { return a.count }

    var previous = Array(0...b.count)
    for (i, left) in a.enumerated() {
        var current = [i + 1] + Array(repeating: 0, count: b.count)
        for (j, right) in b.enumerated() {
            current[j + 1] = min(
                current[j] + 1,
                previous[j + 1] + 1,
                previous[j] + (left == right ? 0 : 1)
            )
        }
        previous = current
    }
    return previous[b.count]
}

func characterErrorRate(reference: String, hypothesis: String) -> Double {
    let normalizedReference = normalizeJapanese(reference)
    let normalizedHypothesis = normalizeJapanese(hypothesis)
    guard !normalizedReference.isEmpty else {
        return normalizedHypothesis.isEmpty ? 0 : 1
    }
    return Double(editDistance(normalizedReference, normalizedHypothesis))
        / Double(normalizedReference.count)
}
