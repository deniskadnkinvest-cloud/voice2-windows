import Foundation

struct VocabularyTerm: Identifiable, Codable, Equatable {
    var id = UUID()
    var canonical: String
    var aliases: [String]

    init(id: UUID = UUID(), canonical: String, aliases: [String] = []) {
        self.id = id
        self.canonical = canonical
        self.aliases = aliases
    }
}

struct VocabularyCandidate: Identifiable, Codable, Equatable {
    var id = UUID()
    var canonical: String
    var rawForms: [String]
    var seenCount: Int
    var firstSeen: Date
    var lastSeen: Date
}

@MainActor
final class Vocabulary: ObservableObject {
    static let shared = Vocabulary()

    @Published var terms: [VocabularyTerm] = [] {
        didSet { save() }
    }

    @Published var candidates: [VocabularyCandidate] = [] {
        didSet { saveCandidates() }
    }

    private let storageKey = "v2.vocabulary"
    private let candidatesKey = "v2.vocabulary.candidates"

    private init() {
        load()
        loadCandidates()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([VocabularyTerm].self, from: data)
        else { return }
        terms = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(terms) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func loadCandidates() {
        guard let data = UserDefaults.standard.data(forKey: candidatesKey),
              let decoded = try? JSONDecoder().decode([VocabularyCandidate].self, from: data)
        else { return }
        candidates = decoded
    }

    private func saveCandidates() {
        guard let data = try? JSONEncoder().encode(candidates) else { return }
        UserDefaults.standard.set(data, forKey: candidatesKey)
    }

    func add(canonical: String, aliases: [String] = []) {
        let c = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return }
        let normalisedAliases = aliases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        terms.insert(VocabularyTerm(canonical: c, aliases: normalisedAliases), at: 0)
    }

    func remove(_ term: VocabularyTerm) {
        terms.removeAll { $0.id == term.id }
    }

    // Whisper initial prompt — comma-separated list of canonical forms.
    // whisper.cpp uses this as decoder context so it leans toward these spellings.
    func whisperPrompt() -> String {
        terms.map { $0.canonical }.joined(separator: ", ")
    }

    // Post-processing: replace any alias occurrence with the canonical form.
    // Case-insensitive, whole-word match. Longest alias first so "Charge 5 Pro"
    // wins over "Charge 5" when both could match.
    func applyAliases(to text: String) -> String {
        var out = text
        let pairs: [(String, String)] = terms.flatMap { term in
            term.aliases.map { ($0, term.canonical) }
        }.sorted { $0.0.count > $1.0.count }

        for (alias, canonical) in pairs {
            out = replaceWholeWord(in: out, find: alias, with: canonical)
        }
        return out
    }

    // Record a candidate discovered by the polisher.
    // If the canonical already exists in `terms` — merge the raw form into its aliases.
    // Otherwise increment an existing candidate's counter (or create a new one).
    func recordCandidate(canonical: String, raw: String) {
        let c = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return }

        // Already a known term — auto-merge raw as alias.
        if let idx = terms.firstIndex(where: { $0.canonical.lowercased() == c.lowercased() }) {
            if !r.isEmpty,
               r.lowercased() != c.lowercased(),
               !terms[idx].aliases.contains(where: { $0.lowercased() == r.lowercased() }) {
                terms[idx].aliases.append(r)
            }
            return
        }

        // Update existing candidate.
        if let idx = candidates.firstIndex(where: { $0.canonical.lowercased() == c.lowercased() }) {
            var cand = candidates[idx]
            cand.seenCount += 1
            cand.lastSeen = Date()
            if !r.isEmpty,
               r.lowercased() != c.lowercased(),
               !cand.rawForms.contains(where: { $0.lowercased() == r.lowercased() }) {
                cand.rawForms.append(r)
            }
            candidates[idx] = cand
            return
        }

        // New candidate.
        let now = Date()
        let rawForms: [String] = (r.isEmpty || r.lowercased() == c.lowercased()) ? [] : [r]
        candidates.insert(
            VocabularyCandidate(canonical: c, rawForms: rawForms, seenCount: 1, firstSeen: now, lastSeen: now),
            at: 0
        )
    }

    func promote(_ candidate: VocabularyCandidate) {
        add(canonical: candidate.canonical, aliases: candidate.rawForms)
        candidates.removeAll { $0.id == candidate.id }
    }

    /// Promote с правкой — оператор поменял canonical и/или список алиасов перед добавлением.
    func promoteEdited(_ candidate: VocabularyCandidate, canonical: String, aliases: [String]) {
        add(canonical: canonical, aliases: aliases)
        candidates.removeAll { $0.id == candidate.id }
    }

    func dismiss(_ candidate: VocabularyCandidate) {
        candidates.removeAll { $0.id == candidate.id }
    }

    // Word-level positional diff between original transcript and user-edited version.
    // Only fires when the user explicitly edits a history entry. If token counts
    // differ — skip; the user can add terms manually via the vocabulary editor.
    func learnFromEdit(original: String, edited: String) {
        let punct = CharacterSet(charactersIn: ".,!?;:«»\"„“()…—–-")
        let originalTokens = original.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let editedTokens = edited.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard originalTokens.count == editedTokens.count else { return }

        for (a, b) in zip(originalTokens, editedTokens) {
            let aClean = a.trimmingCharacters(in: punct)
            let bClean = b.trimmingCharacters(in: punct)
            guard !aClean.isEmpty, !bClean.isEmpty,
                  aClean.lowercased() != bClean.lowercased() else { continue }
            recordCandidate(canonical: bClean, raw: aClean)
        }
    }

    private func replaceWholeWord(in text: String, find: String, with: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: find)
        // \b doesn't work well with Cyrillic; use lookarounds for non-letter boundaries.
        let pattern = "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return re.stringByReplacingMatches(
            in: text, options: [], range: range, withTemplate: with
        )
    }
}
