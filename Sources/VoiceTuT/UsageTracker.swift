import Foundation

@MainActor
final class UsageTracker: ObservableObject {
    static let shared = UsageTracker()

    // Personal build — no limits, no registration.
    static let freeLimit = Int.max
    @Published private(set) var wordsThisMonth: Int = 0
    var isRegistered: Bool  { true }
    var isLimitReached: Bool { false }
    var wordsLeft: Int      { Int.max }
    var progress: Double    { 0 }

    private var monthKey: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        return "words_\(f.string(from: Date()))"
    }

    private init() {
        wordsThisMonth = UserDefaults.standard.integer(forKey: monthKey)
    }

    func addWords(from text: String) {
        guard !text.isEmpty else { return }
        let count = text.split(whereSeparator: \.isWhitespace).count
        wordsThisMonth += count
        UserDefaults.standard.set(wordsThisMonth, forKey: monthKey)
    }
}
