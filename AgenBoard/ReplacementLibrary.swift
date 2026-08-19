import Foundation
import SwiftUI

struct ReplacementRule: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var source: String
    var replacement: String
    var isEnabled: Bool
    let createdAt: Date

    init(
        id: UUID = UUID(),
        source: String,
        replacement: String,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.source = source
        self.replacement = replacement
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }
}

enum ReplacementLibraryStorage {
    static let storageKey = "replacementLibraryRulesV1"
    static let maximumSourceLength = 128
    static let maximumReplacementLength = 500

    private struct StoredLibrary: Codable {
        let version: Int
        let rules: [ReplacementRule]
    }

    static func loadRules() -> [ReplacementRule] {
        guard let defaults = UserDefaults(
            suiteName: SharedCommandStore.appGroupIdentifier
        ), let data = defaults.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode(StoredLibrary.self, from: data),
              stored.version == 1 else {
            return []
        }
        return sanitizedRules(stored.rules)
    }

    static func save(_ rules: [ReplacementRule]) {
        guard let defaults = UserDefaults(
            suiteName: SharedCommandStore.appGroupIdentifier
        ) else {
            return
        }
        let stored = StoredLibrary(version: 1, rules: sanitizedRules(rules))
        guard let data = try? JSONEncoder().encode(stored) else {
            return
        }
        defaults.set(data, forKey: storageKey)
        defaults.synchronize()
    }

    static func normalizedValues(
        source: String,
        replacement: String
    ) -> (source: String, replacement: String)? {
        let source = source
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacement
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty,
              !replacement.isEmpty,
              source.count <= maximumSourceLength,
              replacement.count <= maximumReplacementLength else {
            return nil
        }
        return (
            source.precomposedStringWithCanonicalMapping,
            replacement.precomposedStringWithCanonicalMapping
        )
    }

    static func comparisonKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    static func sanitizedRules(_ candidates: [ReplacementRule]) -> [ReplacementRule] {
        var output: [ReplacementRule] = []
        var indexesBySource: [String: Int] = [:]

        for var rule in candidates {
            guard let values = normalizedValues(
                source: rule.source,
                replacement: rule.replacement
            ) else {
                continue
            }
            rule.source = values.source
            rule.replacement = values.replacement
            let key = comparisonKey(rule.source)
            if let existingIndex = indexesBySource[key] {
                // 匹配忽略大小写；保留首次录入的稳定 ID 和展示写法，
                // 后出现的规则只更新目标和启用状态。
                output[existingIndex].replacement = rule.replacement
                output[existingIndex].isEnabled = rule.isEnabled
                continue
            }
            indexesBySource[key] = output.count
            output.append(rule)
        }
        return output
    }
}

enum TranscriptReplacementEngine {
    struct Rule: Sendable {
        let source: String
        let replacement: String
    }

    static func apply(_ text: String, rules: [Rule]) -> String {
        guard !text.isEmpty, !rules.isEmpty else {
            return text
        }

        let orderedRules = rules
            .filter { !$0.source.isEmpty }
            .sorted { lhs, rhs in
                lhs.source.count > rhs.source.count
            }
        guard !orderedRules.isEmpty else {
            return text
        }

        var output = ""
        output.reserveCapacity(text.count)
        var cursor = text.startIndex
        let compareOptions: String.CompareOptions = [
            .anchored,
            .caseInsensitive,
            .diacriticInsensitive,
            .widthInsensitive
        ]
        let locale = Locale(identifier: "en_US_POSIX")

        while cursor < text.endIndex {
            let searchRange = cursor..<text.endIndex
            var bestMatch: (range: Range<String.Index>, replacement: String)?

            for rule in orderedRules {
                guard let range = text.range(
                    of: rule.source,
                    options: compareOptions,
                    range: searchRange,
                    locale: locale
                ) else {
                    continue
                }
                if let current = bestMatch,
                   text.distance(from: range.lowerBound, to: range.upperBound)
                    <= text.distance(
                        from: current.range.lowerBound,
                        to: current.range.upperBound
                    ) {
                    continue
                }
                bestMatch = (range, rule.replacement)
            }

            if let bestMatch {
                output.append(bestMatch.replacement)
                cursor = bestMatch.range.upperBound
            } else {
                let next = text.index(after: cursor)
                output.append(contentsOf: text[cursor..<next])
                cursor = next
            }
        }

        return output
    }
}

enum SpeechTranscriptNormalizer {
    private static let fixedRules: [TranscriptReplacementEngine.Rule] = [
        .init(source: "斜杠 new", replacement: "/new"),
        .init(source: "斜杠new", replacement: "/new"),
        .init(source: "slash new", replacement: "/new"),
        .init(source: "斜杠 start", replacement: "/start"),
        .init(source: "斜杠start", replacement: "/start"),
        .init(source: "slash start", replacement: "/start"),
        .init(source: "open claw", replacement: "OpenClaw"),
        .init(source: "克劳德 code", replacement: "Claude Code")
    ]

    static func normalize(
        _ text: String,
        replacementRules: [ReplacementRule] = []
    ) -> String {
        let userRules = ReplacementLibraryStorage
            .sanitizedRules(replacementRules)
            .filter(\.isEnabled)
            .map {
                TranscriptReplacementEngine.Rule(
                    source: $0.source,
                    replacement: $0.replacement
                )
            }
        let userSources = Set(
            userRules.map { ReplacementLibraryStorage.comparisonKey($0.source) }
        )
        let fallbackRules = fixedRules.filter {
            !userSources.contains(
                ReplacementLibraryStorage.comparisonKey($0.source)
            )
        }
        return TranscriptReplacementEngine.apply(
            text,
            rules: userRules + fallbackRules
        )
    }
}

@MainActor
final class ReplacementLibraryStore: ObservableObject {
    enum SaveResult {
        case saved
        case duplicate
        case invalid
    }

    @Published private(set) var rules: [ReplacementRule]

    init(loadImmediately: Bool = true) {
        rules = loadImmediately ? ReplacementLibraryStorage.loadRules() : []
    }

    var enabledCount: Int {
        rules.filter(\.isEnabled).count
    }

    @discardableResult
    func add(source: String, replacement: String) -> SaveResult {
        guard let values = ReplacementLibraryStorage.normalizedValues(
            source: source,
            replacement: replacement
        ) else {
            return .invalid
        }
        let key = ReplacementLibraryStorage.comparisonKey(values.source)
        guard !rules.contains(where: {
            ReplacementLibraryStorage.comparisonKey($0.source) == key
        }) else {
            return .duplicate
        }
        rules.append(
            ReplacementRule(
                source: values.source,
                replacement: values.replacement
            )
        )
        persist()
        return .saved
    }

    @discardableResult
    func update(
        id: UUID,
        source: String,
        replacement: String
    ) -> SaveResult {
        guard let index = rules.firstIndex(where: { $0.id == id }),
              let values = ReplacementLibraryStorage.normalizedValues(
                  source: source,
                  replacement: replacement
              ) else {
            return .invalid
        }
        let key = ReplacementLibraryStorage.comparisonKey(values.source)
        guard !rules.enumerated().contains(where: {
            $0.offset != index
                && ReplacementLibraryStorage.comparisonKey($0.element.source) == key
        }) else {
            return .duplicate
        }
        rules[index].source = values.source
        rules[index].replacement = values.replacement
        persist()
        return .saved
    }

    func setEnabled(_ isEnabled: Bool, id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else {
            return
        }
        rules[index].isEnabled = isEnabled
        persist()
    }

    func remove(id: UUID) {
        rules.removeAll { $0.id == id }
        persist()
    }

    func replaceAll(with rules: [ReplacementRule]) {
        self.rules = ReplacementLibraryStorage.sanitizedRules(rules)
        persist()
    }

    func removeAll() {
        rules = []
        persist()
    }

    func refresh() {
        rules = ReplacementLibraryStorage.loadRules()
    }

    private func persist() {
        ReplacementLibraryStorage.save(rules)
        rules = ReplacementLibraryStorage.loadRules()
    }
}

struct ReplacementLibraryView: View {
    @ObservedObject var store: ReplacementLibraryStore

    @State private var source = ""
    @State private var replacement = ""
    @State private var editingID: UUID?
    @State private var searchText = ""
    @State private var message = ""
    @State private var showsClearConfirmation = false

    private var displayedRules: [ReplacementRule] {
        guard !searchText.isEmpty else {
            return store.rules
        }
        return store.rules.filter {
            $0.source.localizedCaseInsensitiveContains(searchText)
                || $0.replacement.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        List {
            Section(editingID == nil ? "添加替换词" : "编辑替换词") {
                TextField("识别结果，例如 Broll", text: $source)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("替换为，例如 B roll", text: $replacement)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                HStack {
                    Button(editingID == nil ? "添加替换词" : "保存修改") {
                        saveDraft()
                    }
                    .disabled(
                        source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || replacement.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                    )

                    if editingID != nil {
                        Button("取消") {
                            resetDraft()
                        }
                    }
                }

                if !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if displayedRules.isEmpty {
                    Text(searchText.isEmpty ? "还没有替换词" : "没有匹配的替换词")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(displayedRules) { rule in
                        HStack(spacing: 12) {
                            Button {
                                beginEditing(rule)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(rule.source)
                                        .foregroundStyle(.primary)
                                    Label(rule.replacement, systemImage: "arrow.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Toggle(
                                "启用 \(rule.source)",
                                isOn: Binding(
                                    get: { rule.isEnabled },
                                    set: { store.setEnabled($0, id: rule.id) }
                                )
                            )
                            .labelsHidden()
                        }
                        .swipeActions {
                            Button("删除", role: .destructive) {
                                if editingID == rule.id {
                                    resetDraft()
                                }
                                store.remove(id: rule.id)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("全部替换词")
                    Spacer()
                    Text("启用 \(store.enabledCount) / 总数 \(store.rules.count)")
                }
            } footer: {
                Text("替换只在本机执行，不会发送到识别服务。匹配忽略大小写，并优先使用更长的规则。")
            }

            Section {
                Button("清空全部替换词", role: .destructive) {
                    showsClearConfirmation = true
                }
                .disabled(store.rules.isEmpty)
            }
        }
        .navigationTitle("替换词")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText)
        .confirmationDialog(
            "清空全部 \(store.rules.count) 条替换词？",
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) {
                store.removeAll()
                resetDraft()
                message = "替换词已清空"
            }
            Button("取消", role: .cancel) {}
        }
        .onAppear {
            store.refresh()
        }
    }

    private func beginEditing(_ rule: ReplacementRule) {
        editingID = rule.id
        source = rule.source
        replacement = rule.replacement
        message = ""
    }

    private func saveDraft() {
        let result: ReplacementLibraryStore.SaveResult
        if let editingID {
            result = store.update(
                id: editingID,
                source: source,
                replacement: replacement
            )
        } else {
            result = store.add(source: source, replacement: replacement)
        }

        switch result {
        case .saved:
            resetDraft()
            message = "替换词已保存"
        case .duplicate:
            message = "相同的识别结果已经存在"
        case .invalid:
            message = "两项都不能为空，识别结果最多 128 字，替换结果最多 500 字"
        }
    }

    private func resetDraft() {
        editingID = nil
        source = ""
        replacement = ""
    }
}
