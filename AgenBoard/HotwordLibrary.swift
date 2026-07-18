import Foundation

struct HotwordEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var term: String
    var isPinned: Bool
    var isEnabled: Bool
    var lastUsedAt: Date?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        term: String,
        isPinned: Bool = false,
        isEnabled: Bool = true,
        lastUsedAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.term = term
        self.isPinned = isPinned
        self.isEnabled = isEnabled
        self.lastUsedAt = lastUsedAt
        self.createdAt = createdAt
    }
}

enum HotwordSelectionPolicy {
    static let maximumActiveCount = 100

    static func select(
        from entries: [HotwordEntry],
        limit: Int = maximumActiveCount
    ) -> [HotwordEntry] {
        guard limit > 0 else {
            return []
        }

        return Array(
            rankedEnabledEntries(from: entries)
                .prefix(limit)
        )
    }

    static func selectedTerms(
        from entries: [HotwordEntry],
        limit: Int = maximumActiveCount
    ) -> [String] {
        select(from: entries, limit: limit).map(\.term)
    }

    static func limitedTerms(
        _ terms: [String],
        limit: Int = maximumActiveCount
    ) -> [String] {
        guard limit > 0 else {
            return []
        }
        return Array(terms.prefix(limit))
    }

    static func rankedEnabledEntries(from entries: [HotwordEntry]) -> [HotwordEntry] {
        entries.enumerated()
            .filter { $0.element.isEnabled }
            .sorted { left, right in
                let lhs = left.element
                let rhs = right.element

                if lhs.isPinned != rhs.isPinned {
                    return lhs.isPinned
                }

                switch (lhs.lastUsedAt, rhs.lastUsedAt) {
                case let (leftDate?, rightDate?) where leftDate != rightDate:
                    return leftDate > rightDate
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return left.offset < right.offset
                }
            }
            .map(\.element)
    }
}

struct HotwordImportReport {
    let addedCount: Int
    let duplicateCount: Int
    let invalidCount: Int
}

enum HotwordLibraryStorage {
    static let legacyStorageKey = "hotwordLibraryTermsV1"
    static let metadataStorageKey = "hotwordLibraryEntriesV2"

    private static let maximumTermLength = 128
    private static let initialTerms = [
        "AgenBoard",
        "OpenClaw",
        "Claude Code",
        "Codex",
        "Hermes",
        "斜杠 new",
        "斜杠 start",
        "/new",
        "/start"
    ]

    private struct StoredLibrary: Codable {
        let version: Int
        let entries: [HotwordEntry]
    }

    static func loadEntries() -> [HotwordEntry] {
        guard let defaults = UserDefaults(suiteName: SharedCommandStore.appGroupIdentifier) else {
            return migratedEntries(from: initialTerms)
        }
        return loadEntries(from: defaults)
    }

    static func loadEntries(from defaults: UserDefaults) -> [HotwordEntry] {
        if let data = defaults.data(forKey: metadataStorageKey),
           let stored = try? JSONDecoder().decode(StoredLibrary.self, from: data),
           stored.version == 2 {
            return sanitizedEntries(stored.entries)
        }

        let legacyTerms: [String]
        if defaults.object(forKey: legacyStorageKey) != nil {
            legacyTerms = defaults.stringArray(forKey: legacyStorageKey) ?? []
        } else {
            legacyTerms = initialTerms
        }

        let entries = migratedEntries(from: legacyTerms)
        save(entries, to: defaults)
        return entries
    }

    static func loadTerms() -> [String] {
        loadEntries().map(\.term)
    }

    static func save(_ entries: [HotwordEntry]) {
        guard let defaults = UserDefaults(suiteName: SharedCommandStore.appGroupIdentifier) else {
            return
        }
        save(entries, to: defaults)
    }

    static func save(_ entries: [HotwordEntry], to defaults: UserDefaults) {
        let sanitized = sanitizedEntries(entries)
        let stored = StoredLibrary(version: 2, entries: sanitized)
        guard let data = try? JSONEncoder().encode(stored) else {
            return
        }

        // V2 is authoritative. V1 remains a complete compatibility copy so upgrading
        // never truncates an existing library and older builds can still read all terms.
        defaults.set(data, forKey: metadataStorageKey)
        defaults.set(sanitized.map(\.term), forKey: legacyStorageKey)
        defaults.synchronize()
    }

    static func markTermsUsed(_ terms: [String], at date: Date = Date()) {
        guard !terms.isEmpty else {
            return
        }

        let usedKeys = Set(terms.map(comparisonKey))
        var entries = loadEntries()
        var didChange = false

        for index in entries.indices {
            guard usedKeys.contains(comparisonKey(entries[index].term)) else {
                continue
            }
            entries[index].lastUsedAt = date
            didChange = true
        }

        if didChange {
            save(entries)
        }
    }

    static func parseTerms(from text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "\u{FEFF}", with: "") }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    static func normalizedTerm(_ candidate: String) -> String? {
        let term = candidate
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.count <= maximumTermLength else {
            return nil
        }
        return term.precomposedStringWithCanonicalMapping
    }

    static func comparisonKey(_ term: String) -> String {
        term.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func migratedEntries(from candidates: [String]) -> [HotwordEntry] {
        deduplicatedTerms(candidates).enumerated().map { index, term in
            HotwordEntry(
                term: term,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
    }

    private static func sanitizedEntries(_ candidates: [HotwordEntry]) -> [HotwordEntry] {
        var keys = Set<String>()
        var output: [HotwordEntry] = []

        for var entry in candidates {
            guard let term = normalizedTerm(entry.term) else {
                continue
            }
            guard keys.insert(comparisonKey(term)).inserted else {
                continue
            }
            entry.term = term
            output.append(entry)
        }
        return output
    }

    private static func deduplicatedTerms(_ candidates: [String]) -> [String] {
        var keys = Set<String>()
        var output: [String] = []

        for candidate in candidates {
            guard let term = normalizedTerm(candidate) else {
                continue
            }
            if keys.insert(comparisonKey(term)).inserted {
                output.append(term)
            }
        }
        return output
    }
}
