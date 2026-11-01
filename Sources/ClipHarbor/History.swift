import Foundation

enum Clip: Codable, Hashable {
    case text(String)
    case image(Data)
    case files([String])
    case rich([[String: Data]])

    var duplicateKey: Clip {
        if case .text(let text) = self {
            return .text(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").precomposedStringWithCanonicalMapping)
        }
        return self
    }
}

struct Usage: Codable {
    var item: Clip
    var count: Int
}

struct Archive: Codable {
    var items: [Clip]
    var pinned: [Clip]
    var usage: [Usage]? = nil
}

struct History {
    private(set) var items: [Clip]
    private(set) var pinned: [Clip]
    private(set) var usage: [Usage]
    let limit: Int

    init(items: [Clip] = [], pinned: [Clip] = [], usage: [Usage] = [], limit: Int = 100) {
        let pinKeys = Set(pinned.map(\.duplicateKey))
        var seen = Set<Clip>()
        let unique = items.compactMap { item -> Clip? in
            guard seen.insert(item.duplicateKey).inserted else { return nil }
            return pinned.first { $0.duplicateKey == item.duplicateKey && items.contains($0) } ?? item
        }
        let pinnedItems = unique.filter { pinKeys.contains($0.duplicateKey) }
        self.pinned = pinnedItems
        self.items = pinnedItems + Array(unique.filter { !pinKeys.contains($0.duplicateKey) }.prefix(limit))
        let keptKeys = Set(self.items.map(\.duplicateKey))
        var totals: [Clip: Int] = [:]
        for entry in usage where entry.count > 0 && keptKeys.contains(entry.item.duplicateKey) {
            let key = entry.item.duplicateKey
            let (sum, overflow) = (totals[key] ?? 0).addingReportingOverflow(entry.count)
            totals[key] = overflow ? Int.max : sum
        }
        self.usage = self.items.compactMap { item in totals[item.duplicateKey].map { Usage(item: item, count: $0) } }
        self.limit = limit
    }

    mutating func add(_ item: Clip) {
        if case .text(let text) = item, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        guard !items.contains(where: { $0.duplicateKey == item.duplicateKey }) else { return }
        items.insert(item, at: pinned.count)
        trim()
    }

    func count(for item: Clip) -> Int {
        usage.first { $0.item.duplicateKey == item.duplicateKey }?.count ?? 0
    }

    var frequent: [Clip] {
        items.enumerated().filter { count(for: $0.element) > 0 }.sorted {
            let leftPinned = pinned.contains($0.element), rightPinned = pinned.contains($1.element)
            if leftPinned != rightPinned { return leftPinned }
            let left = count(for: $0.element), right = count(for: $1.element)
            return left == right ? $0.offset < $1.offset : left > right
        }.map(\.element)
    }

    mutating func recordUse(_ item: Clip) {
        guard let item = items.first(where: { $0.duplicateKey == item.duplicateKey }) else { return }
        if let index = usage.firstIndex(where: { $0.item.duplicateKey == item.duplicateKey }) {
            if usage[index].count < Int.max { usage[index].count += 1 }
        } else {
            usage.append(Usage(item: item, count: 1))
        }
    }

    mutating func togglePin(_ item: Clip) {
        guard let index = items.firstIndex(of: item) else { return }
        items.remove(at: index)
        if let index = pinned.firstIndex(of: item) {
            pinned.remove(at: index)
            items.insert(item, at: pinned.count)
        } else {
            pinned.append(item)
            items.insert(item, at: pinned.count - 1)
        }
        trim()
    }

    mutating func clear() {
        items = items.filter { pinned.contains($0) }
        pruneUsage()
    }

    private mutating func trim() {
        let keep = Set(items.filter { !pinned.contains($0) }.prefix(limit))
        items.removeAll { !pinned.contains($0) && !keep.contains($0) }
        pruneUsage()
    }

    private mutating func pruneUsage() {
        let keptKeys = Set(items.map(\.duplicateKey))
        usage.removeAll { !keptKeys.contains($0.item.duplicateKey) }
    }
}
