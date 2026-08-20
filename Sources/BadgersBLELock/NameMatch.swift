import Foundation

/// Words that appear in almost every Apple device name and therefore carry no
/// information about *whose* device it is.
private let noiseTokens: Set<String> = [
    "iphone", "ipad", "ipod", "watch", "airpods", "macbook", "mac", "apple",
    "phone", "pro", "max", "mini", "plus", "air", "ultra", "my", "the",
]

private func normalize(_ s: String) -> String {
    s.lowercased().unicodeScalars
        .filter { CharacterSet.alphanumerics.contains($0) }
        .map(String.init)
        .joined()
}

private func tokens(_ s: String) -> [String] {
    s.lowercased()
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .map(String.init)
        .filter { $0.count >= 3 && !noiseTokens.contains($0) && Int($0) == nil }
}

enum NameMatch {
    /// The account identities we try to match device names against.
    static var identities: [String] {
        [NSUserName(), NSFullUserName()].filter { !$0.isEmpty }
    }

    /// Rough confidence that `deviceName` belongs to the logged-in user.
    /// Scores are only ever compared against each other, never to an absolute bar.
    ///
    /// "markterrill" vs "Mark's iPhone 14" matches on the token "mark" being a
    /// substring of the account name, which is the common real-world shape.
    static func score(deviceName: String) -> Int {
        let normalizedIdentities = identities.map(normalize)
        let identityTokens = identities.flatMap(tokens)
        let normalizedDevice = normalize(deviceName)
        var score = 0

        for token in tokens(deviceName) {
            // "mark" found inside the account name "markterrill"
            if normalizedIdentities.contains(where: { $0.contains(token) }) {
                score += token.count * 2
            }
        }
        for token in identityTokens {
            // "terrill" found inside the device name "Terrill iPhone"
            if normalizedDevice.contains(token) {
                score += token.count * 2
            }
        }
        // Shared leading characters catch abbreviated names ("mterrill" / "Mark's iPhone")
        for identity in normalizedIdentities where !identity.isEmpty && !normalizedDevice.isEmpty {
            let shared = zip(identity, normalizedDevice).prefix { $0 == $1 }.count
            if shared >= 3 { score += shared }
        }
        return score
    }

    /// The single best candidate, but only when it clearly beats the runner-up —
    /// two equally-good guesses are worse than none in a busy office.
    static func bestGuess(among names: [(id: UUID, name: String)]) -> UUID? {
        let scored = names.map { (id: $0.id, score: score(deviceName: $0.name)) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
        guard let top = scored.first else { return nil }
        if scored.count > 1 && scored[1].score >= top.score { return nil }
        return top.id
    }
}
