import CryptoKit
import Foundation
import ZIPFoundation

enum PortableImportMode: String, CaseIterable, Identifiable, Sendable {
    case merge
    case replace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .merge:
            return "智能合并"
        case .replace:
            return "完全替换"
        }
    }
}

struct PortableDataCounts: Codable, Equatable, Sendable {
    let hotwords: Int
    let quickPhrases: Int
    let recognitionHistory: Int
    let recordings: Int
    let pinyinEntries: Int

    init(
        hotwords: Int,
        quickPhrases: Int,
        recognitionHistory: Int,
        recordings: Int,
        pinyinEntries: Int = 0
    ) {
        self.hotwords = hotwords
        self.quickPhrases = quickPhrases
        self.recognitionHistory = recognitionHistory
        self.recordings = recordings
        self.pinyinEntries = pinyinEntries
    }

    private enum CodingKeys: String, CodingKey {
        case hotwords
        case quickPhrases
        case recognitionHistory
        case recordings
        case pinyinEntries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hotwords = try container.decode(Int.self, forKey: .hotwords)
        quickPhrases = try container.decode(Int.self, forKey: .quickPhrases)
        recognitionHistory = try container.decode(Int.self, forKey: .recognitionHistory)
        recordings = try container.decode(Int.self, forKey: .recordings)
        pinyinEntries = try container.decodeIfPresent(
            Int.self,
            forKey: .pinyinEntries
        ) ?? 0
    }
}

struct PortableMergeSummary: Equatable, Sendable {
    let newHotwords: Int
    let updatedHotwords: Int
    let duplicateHotwords: Int
    let newQuickPhrases: Int
    let updatedQuickPhrases: Int
    let duplicateQuickPhrases: Int
    let newHistoryItems: Int
    let existingHistoryItems: Int
}

struct PortableImportPreview: Identifiable, Sendable {
    let id = UUID()
    let fileName: String
    let exportedAt: Date
    let appVersion: String
    let counts: PortableDataCounts
    let credentialsIncluded: Bool
    let pinyinIncluded: Bool
    let mergeSummary: PortableMergeSummary
    let warnings: [String]

    fileprivate let payload: PortableImportPayload
}

struct PortableImportResult: Equatable, Sendable {
    let mode: PortableImportMode
    let hotwordCount: Int
    let quickPhraseCount: Int
    let historyCount: Int
    let pinyinEntryCount: Int?
}

@MainActor
final class PortableDataService {
    static let shared = PortableDataService()

    private init() {}

    func createCompleteExport(
        historyStore: RecognitionHistoryStore,
        hotwordStore: HotwordLibraryStore,
        quickPhraseStore: QuickPhraseLibraryStore,
        includeRecordings: Bool,
        includeCredentials: Bool
    ) async throws -> URL {
        historyStore.loadIfNeeded()
        hotwordStore.refresh()
        quickPhraseStore.refresh()

        let bundle = Bundle.main
        let appVersion = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        let buildNumber = bundle.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown"

        let aliyunConfigured = AliyunCredentialStore.hasAPIKey
        let exportedAPIKey = includeCredentials
            ? try AliyunCredentialStore.apiKey()
            : nil
        let recordingItems = includeRecordings
            ? historyStore.items.filter {
                $0.hasRecording && FileManager.default.fileExists(
                    atPath: historyStore.audioURL(for: $0).path
                )
            }
            : []
        let recordingIDs = Set(recordingItems.map(\.id))
        let pinyinSnapshot = try await Task.detached(priority: .utility) {
            try SharedPinyinUserDataStore.latestSnapshot()
        }.value
        let snapshot = PortableExportSnapshot(
            exportedAt: Date(),
            appVersion: appVersion,
            buildNumber: buildNumber,
            preferences: PortablePreferencesDocument.current(
                aliyunConfigured: aliyunConfigured,
                credentialsIncluded: exportedAPIKey != nil
            ),
            credentials: exportedAPIKey.map {
                PortableCredentialsDocument(
                    format: "agenboard-credentials",
                    schemaVersion: 1,
                    aliyunApiKey: $0
                )
            },
            hotwords: hotwordStore.entries.map(PortableHotword.init),
            quickPhrases: quickPhraseStore.phrases.map(PortableQuickPhrase.init),
            history: historyStore.items.map {
                PortableRecognitionRecord(
                    $0,
                    includeRecording: recordingIDs.contains($0.id)
                )
            },
            recordings: recordingItems.map {
                PortableRecordingSource(
                    fileName: $0.audioFileName,
                    sourceURL: historyStore.audioURL(for: $0)
                )
            },
            pinyin: pinyinSnapshot.map {
                PortablePinyinSource(
                    sourceURL: $0.url,
                    entryCount: $0.entryCount
                )
            }
        )

        return try await Task.detached(priority: .userInitiated) {
            try PortablePackageBuilder.build(snapshot: snapshot)
        }.value
    }

    func prepareImport(
        from sourceURL: URL,
        historyStore: RecognitionHistoryStore,
        hotwordStore: HotwordLibraryStore,
        quickPhraseStore: QuickPhraseLibraryStore
    ) async throws -> PortableImportPreview {
        let fileManager = FileManager.default
        let workDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("AgenBoardPortableImports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: workDirectory,
            withIntermediateDirectories: true
        )
        let localArchiveURL = workDirectory.appendingPathComponent("import.zip")

        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            try fileManager.copyItem(at: sourceURL, to: localArchiveURL)
        } catch {
            try? fileManager.removeItem(at: workDirectory)
            throw PortableDataError.cannotReadSelectedFile(error.localizedDescription)
        }

        let payload: PortableImportPayload
        do {
            payload = try await Task.detached(priority: .userInitiated) {
                try PortablePackageReader.read(
                    archiveURL: localArchiveURL,
                    workDirectory: workDirectory,
                    sourceFileName: sourceURL.lastPathComponent
                )
            }.value
        } catch {
            try? fileManager.removeItem(at: workDirectory)
            throw error
        }

        historyStore.loadIfNeeded()
        hotwordStore.refresh()
        quickPhraseStore.refresh()

        return PortableImportPreview(
            fileName: payload.sourceFileName,
            exportedAt: payload.manifest.exportedAt,
            appVersion: payload.manifest.appVersion,
            counts: payload.counts,
            credentialsIncluded: payload.credentials != nil,
            pinyinIncluded: payload.pinyinSnapshotURL != nil,
            mergeSummary: analyzeMerge(
                payload: payload,
                currentHotwords: hotwordStore.entries,
                currentQuickPhrases: quickPhraseStore.phrases,
                currentHistory: historyStore.items
            ),
            warnings: payload.warnings,
            payload: payload
        )
    }

    func applyImport(
        _ preview: PortableImportPreview,
        mode: PortableImportMode,
        historyStore: RecognitionHistoryStore,
        hotwordStore: HotwordLibraryStore,
        quickPhraseStore: QuickPhraseLibraryStore
    ) throws -> PortableImportResult {
        let payload = preview.payload
        historyStore.loadIfNeeded()
        hotwordStore.refresh()
        quickPhraseStore.refresh()

        let finalHotwords = mode == .replace
            ? payload.hotwords
            : mergeHotwords(current: hotwordStore.entries, imported: payload.hotwords)
        let finalQuickPhrases = mode == .replace
            ? payload.quickPhrases
            : mergeQuickPhrases(
                current: quickPhraseStore.phrases,
                imported: payload.quickPhrases
            )

        let previousAPIKey = try AliyunCredentialStore.apiKey()
        let importedAPIKey = payload.credentials?.aliyunApiKey
        let credentialChanged = importedAPIKey != nil && importedAPIKey != previousAPIKey
        if let importedAPIKey, credentialChanged {
            try AliyunCredentialStore.saveAPIKey(importedAPIKey)
        }

        do {
            try historyStore.importPortableItems(
                payload.history,
                recordingsDirectory: payload.recordingsDirectory,
                mode: mode
            )
            if let pinyinSnapshotURL = payload.pinyinSnapshotURL {
                try SharedPinyinUserDataStore.stageImport(
                    from: pinyinSnapshotURL,
                    mode: mode == .replace ? .replace : .merge
                )
            }
        } catch {
            if credentialChanged {
                restoreCredential(previousAPIKey)
            }
            throw error
        }

        HotwordLibraryStorage.save(finalHotwords)
        SharedCommandStore.saveQuickPhrases(finalQuickPhrases)
        apply(preferences: payload.preferences)

        hotwordStore.refresh()
        quickPhraseStore.refresh()
        try? FileManager.default.removeItem(at: payload.workDirectory)

        return PortableImportResult(
            mode: mode,
            hotwordCount: hotwordStore.entries.count,
            quickPhraseCount: quickPhraseStore.phrases.count,
            historyCount: historyStore.items.count,
            pinyinEntryCount: payload.pinyinSnapshotURL == nil
                ? nil
                : payload.counts.pinyinEntries
        )
    }

    func discardImport(_ preview: PortableImportPreview) {
        try? FileManager.default.removeItem(at: preview.payload.workDirectory)
    }

    func discardExport(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func apply(preferences: PortablePreferencesDocument) {
        RecognitionPreferences.defaults.set(
            preferences.recognition.usesHotwords,
            forKey: RecognitionPreferences.useHotwordsKey
        )
        SpeechServicePreferences.provider = preferences.recognition.provider
        SharedCommandStore.setKeyboardQuickPhraseModuleVisible(
            preferences.keyboard.showsQuickPhraseModule
        )
        SharedCommandStore.setKeyboardHapticsEnabled(
            preferences.keyboard.hapticsEnabled
        )
        if let module = preferences.keyboard.selectedModule,
           let rawValue = PortableKeyboardModule(rawValue: module)?.internalRawValue {
            SharedCommandStore.setKeyboardSelectedContentModuleRawValue(rawValue)
        }
        RecognitionPreferences.defaults.synchronize()
    }

    private func restoreCredential(_ value: String?) {
        if let value {
            try? AliyunCredentialStore.saveAPIKey(value)
        } else {
            try? AliyunCredentialStore.deleteAPIKey()
        }
    }

    private func analyzeMerge(
        payload: PortableImportPayload,
        currentHotwords: [HotwordEntry],
        currentQuickPhrases: [SharedQuickPhrase],
        currentHistory: [RecognitionHistoryItem]
    ) -> PortableMergeSummary {
        let hotwordIDs = Set(currentHotwords.map(\.id))
        let hotwordKeys = Set(
            currentHotwords.map { HotwordLibraryStorage.comparisonKey($0.term) }
        )
        let updatedHotwords = payload.hotwords.filter { hotwordIDs.contains($0.id) }.count
        let duplicateHotwords = payload.hotwords.filter {
            !hotwordIDs.contains($0.id)
                && hotwordKeys.contains(HotwordLibraryStorage.comparisonKey($0.term))
        }.count

        let quickPhraseIDs = Set(currentQuickPhrases.map(\.id))
        let quickPhraseKeys = Set(currentQuickPhrases.map { quickPhraseKey($0.content) })
        let updatedQuickPhrases = payload.quickPhrases.filter {
            quickPhraseIDs.contains($0.id)
        }.count
        let duplicateQuickPhrases = payload.quickPhrases.filter {
            !quickPhraseIDs.contains($0.id)
                && quickPhraseKeys.contains(quickPhraseKey($0.content))
        }.count

        let historyIDs = Set(currentHistory.map(\.id))
        let existingHistoryItems = payload.history.filter {
            historyIDs.contains($0.id)
        }.count

        return PortableMergeSummary(
            newHotwords: payload.hotwords.count - updatedHotwords - duplicateHotwords,
            updatedHotwords: updatedHotwords,
            duplicateHotwords: duplicateHotwords,
            newQuickPhrases:
                payload.quickPhrases.count - updatedQuickPhrases - duplicateQuickPhrases,
            updatedQuickPhrases: updatedQuickPhrases,
            duplicateQuickPhrases: duplicateQuickPhrases,
            newHistoryItems: payload.history.count - existingHistoryItems,
            existingHistoryItems: existingHistoryItems
        )
    }

    private func mergeHotwords(
        current: [HotwordEntry],
        imported: [HotwordEntry]
    ) -> [HotwordEntry] {
        var result = current

        for entry in imported {
            let incomingKey = HotwordLibraryStorage.comparisonKey(entry.term)
            if let index = result.firstIndex(where: { $0.id == entry.id }) {
                let conflictsWithOtherEntry = result.enumerated().contains {
                    $0.offset != index
                        && HotwordLibraryStorage.comparisonKey($0.element.term) == incomingKey
                }
                if !conflictsWithOtherEntry {
                    result[index] = entry
                }
            } else if !result.contains(where: {
                HotwordLibraryStorage.comparisonKey($0.term) == incomingKey
            }) {
                result.append(entry)
            }
        }
        return result
    }

    private func mergeQuickPhrases(
        current: [SharedQuickPhrase],
        imported: [SharedQuickPhrase]
    ) -> [SharedQuickPhrase] {
        var result = current

        for phrase in imported {
            let incomingKey = quickPhraseKey(phrase.content)
            if let index = result.firstIndex(where: { $0.id == phrase.id }) {
                let conflictsWithOtherPhrase = result.enumerated().contains {
                    $0.offset != index
                        && quickPhraseKey($0.element.content) == incomingKey
                }
                if !conflictsWithOtherPhrase {
                    result[index] = phrase
                }
            } else if !result.contains(where: {
                quickPhraseKey($0.content) == incomingKey
            }) {
                result.append(phrase)
            }
        }
        return result
    }

    private func quickPhraseKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

private struct PortableExportSnapshot: Sendable {
    let exportedAt: Date
    let appVersion: String
    let buildNumber: String
    let preferences: PortablePreferencesDocument
    let credentials: PortableCredentialsDocument?
    let hotwords: [PortableHotword]
    let quickPhrases: [PortableQuickPhrase]
    let history: [PortableRecognitionRecord]
    let recordings: [PortableRecordingSource]
    let pinyin: PortablePinyinSource?
}

private struct PortableRecordingSource: Sendable {
    let fileName: String
    let sourceURL: URL
}

private struct PortablePinyinSource: Sendable {
    let sourceURL: URL
    let entryCount: Int
}

private struct PortableImportPayload: Sendable {
    let sourceFileName: String
    let workDirectory: URL
    let manifest: PortableManifest
    let counts: PortableDataCounts
    let preferences: PortablePreferencesDocument
    let credentials: PortableCredentialsDocument?
    let hotwords: [HotwordEntry]
    let quickPhrases: [SharedQuickPhrase]
    let history: [RecognitionHistoryItem]
    let recordingsDirectory: URL
    let pinyinSnapshotURL: URL?
    let warnings: [String]
}

private struct PortableManifest: Codable, Sendable {
    let format: String
    let schemaVersion: Int
    let exportedAt: Date
    let appVersion: String
    let buildNumber: String
    let counts: PortableDataCounts
    let credentialsIncluded: Bool
    let files: [PortableFileDescriptor]
}

private struct PortableFileDescriptor: Codable, Sendable {
    let path: String
    let byteCount: Int64
    let sha256: String
}

private struct PortableHotwordsDocument: Codable, Sendable {
    let format: String
    let schemaVersion: Int
    let hotwords: [PortableHotword]
}

private struct PortableHotword: Codable, Sendable {
    let id: UUID
    let term: String
    let enabled: Bool
    let pinned: Bool
    let createdAt: Date
    let lastUsedAt: Date?

    init(_ entry: HotwordEntry) {
        id = entry.id
        term = entry.term
        enabled = entry.isEnabled
        pinned = entry.isPinned
        createdAt = entry.createdAt
        lastUsedAt = entry.lastUsedAt
    }

    var entry: HotwordEntry {
        HotwordEntry(
            id: id,
            term: term,
            isPinned: pinned,
            isEnabled: enabled,
            lastUsedAt: lastUsedAt,
            createdAt: createdAt
        )
    }
}

private struct PortableQuickPhrasesDocument: Codable, Sendable {
    let format: String
    let schemaVersion: Int
    let quickPhrases: [PortableQuickPhrase]
}

private struct PortableQuickPhrase: Codable, Sendable {
    let id: UUID
    let title: String
    let content: String
    let enabled: Bool
    let createdAt: Date

    init(_ phrase: SharedQuickPhrase) {
        id = phrase.id
        title = phrase.title
        content = phrase.content
        enabled = phrase.isEnabled
        createdAt = phrase.createdAt
    }

    var phrase: SharedQuickPhrase {
        SharedQuickPhrase(
            id: id,
            title: title,
            content: content,
            isEnabled: enabled,
            createdAt: createdAt
        )
    }
}

private struct PortablePreferencesDocument: Codable, Sendable {
    let format: String
    let schemaVersion: Int
    let recognition: PortableRecognitionPreferences
    let keyboard: PortableKeyboardPreferences
    let credentials: PortableCredentialDisclosure

    @MainActor
    static func current(
        aliyunConfigured: Bool,
        credentialsIncluded: Bool
    ) -> PortablePreferencesDocument {
        PortablePreferencesDocument(
            format: "agenboard-preferences",
            schemaVersion: 1,
            recognition: PortableRecognitionPreferences(
                provider: SpeechServicePreferences.provider,
                usesHotwords: RecognitionPreferences.usesHotwords
            ),
            keyboard: PortableKeyboardPreferences(
                showsQuickPhraseModule: SharedCommandStore.keyboardQuickPhraseModuleVisible(),
                hapticsEnabled: SharedCommandStore.keyboardHapticsEnabled(),
                selectedModule: PortableKeyboardModule(
                    internalRawValue: SharedCommandStore.keyboardSelectedContentModuleRawValue()
                )?.rawValue
            ),
            credentials: PortableCredentialDisclosure(
                aliyunApiKeyIncluded: credentialsIncluded,
                aliyunConfiguredOnExportingDevice: aliyunConfigured
            )
        )
    }
}

private struct PortableCredentialsDocument: Codable, Sendable {
    let format: String
    let schemaVersion: Int
    let aliyunApiKey: String
}

private struct PortableRecognitionPreferences: Codable, Sendable {
    let provider: SpeechRecognitionProvider
    let usesHotwords: Bool
}

private struct PortableKeyboardPreferences: Codable, Sendable {
    let showsQuickPhraseModule: Bool
    let hapticsEnabled: Bool
    let selectedModule: String?
}

private struct PortableCredentialDisclosure: Codable, Sendable {
    let aliyunApiKeyIncluded: Bool
    let aliyunConfiguredOnExportingDevice: Bool
}

private enum PortableKeyboardModule: String, Codable, Sendable {
    case voice
    case quickPhrases = "quick_phrases"
    case keyboard

    init?(internalRawValue: Int?) {
        switch internalRawValue {
        case 0:
            self = .voice
        case 1:
            self = .quickPhrases
        case 2:
            self = .keyboard
        default:
            return nil
        }
    }

    var internalRawValue: Int {
        switch self {
        case .voice:
            return 0
        case .quickPhrases:
            return 1
        case .keyboard:
            return 2
        }
    }
}

private struct PortableRecognitionRecord: Codable, Sendable {
    let id: UUID
    let createdAt: Date
    let audio: PortableAudioReference
    let originalRequest: PortableOriginalRecognitionRequest?
    let withHotwords: PortableRecognitionResult?
    let withoutHotwords: PortableRecognitionResult?
    let benchmarkResults: [RecognitionBenchmarkResult]?
    let lastError: PortableRecognitionError?

    init(_ item: RecognitionHistoryItem, includeRecording: Bool) {
        id = item.id
        createdAt = item.createdAt
        audio = PortableAudioReference(
            included: includeRecording,
            file: includeRecording ? "recordings/\(item.audioFileName)" : nil,
            durationSeconds: item.duration,
            sizeBytes: item.fileSize
        )
        if item.originalMode != nil || item.originalProvider != nil {
            originalRequest = PortableOriginalRecognitionRequest(
                mode: item.originalMode,
                provider: item.originalProvider
            )
        } else {
            originalRequest = nil
        }
        withHotwords = PortableRecognitionResult.make(
            transcript: item.transcriptWithHotwords,
            elapsedSeconds: item.withHotwordsElapsed,
            configuredHotwordCount: item.withHotwordsConfiguredCount,
            matchedTerms: item.withHotwordsMatchedTerms,
            provider: item.withHotwordsProvider,
            words: item.withHotwordsWords,
            realtimeMetrics: item.withHotwordsRealtimeMetrics
        )
        withoutHotwords = PortableRecognitionResult.make(
            transcript: item.transcriptWithoutHotwords,
            elapsedSeconds: item.withoutHotwordsElapsed,
            configuredHotwordCount: nil,
            matchedTerms: item.withoutHotwordsMatchedTerms,
            provider: item.withoutHotwordsProvider,
            words: item.withoutHotwordsWords,
            realtimeMetrics: item.withoutHotwordsRealtimeMetrics
        )
        benchmarkResults = item.benchmarkResults
        if let message = item.lastError {
            lastError = PortableRecognitionError(
                message: message,
                mode: item.lastErrorMode,
                provider: item.lastErrorProvider
            )
        } else {
            lastError = nil
        }
    }

    func item(recordingAvailable: Bool, fileName: String?) -> RecognitionHistoryItem {
        return RecognitionHistoryItem(
            id: id,
            createdAt: createdAt,
            audioFileName: fileName ?? "\(id.uuidString).m4a",
            duration: audio.durationSeconds,
            fileSize: audio.sizeBytes,
            originalMode: originalRequest?.mode,
            originalProvider: originalRequest?.provider,
            transcriptWithHotwords: withHotwords?.transcript,
            transcriptWithoutHotwords: withoutHotwords?.transcript,
            withHotwordsElapsed: withHotwords?.elapsedSeconds,
            withoutHotwordsElapsed: withoutHotwords?.elapsedSeconds,
            withHotwordsConfiguredCount: withHotwords?.configuredHotwordCount,
            withHotwordsMatchedTerms: withHotwords?.matchedTerms,
            withoutHotwordsMatchedTerms: withoutHotwords?.matchedTerms,
            withHotwordsProvider: withHotwords?.provider,
            withoutHotwordsProvider: withoutHotwords?.provider,
            withHotwordsWords: withHotwords?.words,
            withoutHotwordsWords: withoutHotwords?.words,
            withHotwordsRealtimeMetrics: withHotwords?.realtimeMetrics,
            withoutHotwordsRealtimeMetrics: withoutHotwords?.realtimeMetrics,
            benchmarkResults: benchmarkResults,
            lastError: lastError?.message,
            lastErrorMode: lastError?.mode,
            lastErrorProvider: lastError?.provider,
            recordingAvailable: recordingAvailable
        )
    }
}

private struct PortableAudioReference: Codable, Sendable {
    let included: Bool?
    let file: String?
    let durationSeconds: TimeInterval
    let sizeBytes: Int64

    var includesFile: Bool {
        included ?? (file != nil)
    }
}

private struct PortableOriginalRecognitionRequest: Codable, Sendable {
    let mode: RecognitionHotwordMode?
    let provider: SpeechRecognitionProvider?
}

private struct PortableRecognitionResult: Codable, Sendable {
    let transcript: String?
    let elapsedSeconds: TimeInterval?
    let configuredHotwordCount: Int?
    let matchedTerms: [String]?
    let provider: SpeechRecognitionProvider?
    let words: [SpeechRecognitionWord]?
    let realtimeMetrics: AliyunRealtimeRecognitionMetrics?

    static func make(
        transcript: String?,
        elapsedSeconds: TimeInterval?,
        configuredHotwordCount: Int?,
        matchedTerms: [String]?,
        provider: SpeechRecognitionProvider?,
        words: [SpeechRecognitionWord]?,
        realtimeMetrics: AliyunRealtimeRecognitionMetrics?
    ) -> PortableRecognitionResult? {
        guard transcript != nil
                || elapsedSeconds != nil
                || configuredHotwordCount != nil
                || matchedTerms != nil
                || provider != nil
                || words != nil
                || realtimeMetrics != nil else {
            return nil
        }
        return PortableRecognitionResult(
            transcript: transcript,
            elapsedSeconds: elapsedSeconds,
            configuredHotwordCount: configuredHotwordCount,
            matchedTerms: matchedTerms,
            provider: provider,
            words: words,
            realtimeMetrics: realtimeMetrics
        )
    }
}

private struct PortableRecognitionError: Codable, Sendable {
    let message: String
    let mode: RecognitionHotwordMode?
    let provider: SpeechRecognitionProvider?
}

private enum PortablePackageBuilder {
    static func build(snapshot: PortableExportSnapshot) throws -> URL {
        let fileManager = FileManager.default
        let taskDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("AgenBoardPortableExports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let packageDirectory = taskDirectory.appendingPathComponent(
            "AgenBoard-Portable-Data",
            isDirectory: true
        )
        let recordingsDirectory = packageDirectory.appendingPathComponent(
            "recordings",
            isDirectory: true
        )
        let pinyinDirectory = packageDirectory.appendingPathComponent(
            "pinyin",
            isDirectory: true
        )

        do {
            try fileManager.createDirectory(
                at: recordingsDirectory,
                withIntermediateDirectories: true
            )

            let hotwordDocument = PortableHotwordsDocument(
                format: "agenboard-hotwords",
                schemaVersion: 1,
                hotwords: snapshot.hotwords
            )
            let quickPhraseDocument = PortableQuickPhrasesDocument(
                format: "agenboard-quick-phrases",
                schemaVersion: 1,
                quickPhrases: snapshot.quickPhrases
            )

            try PortableJSON.prettyEncoder.encode(snapshot.preferences).write(
                to: packageDirectory.appendingPathComponent("preferences.json"),
                options: .atomic
            )
            try PortableJSON.prettyEncoder.encode(hotwordDocument).write(
                to: packageDirectory.appendingPathComponent("hotwords.json"),
                options: .atomic
            )
            try PortableJSON.prettyEncoder.encode(quickPhraseDocument).write(
                to: packageDirectory.appendingPathComponent("quick-phrases.json"),
                options: .atomic
            )
            if let credentials = snapshot.credentials {
                try PortableJSON.prettyEncoder.encode(credentials).write(
                    to: packageDirectory.appendingPathComponent("credentials.json"),
                    options: .atomic
                )
            }
            try writeJSONLines(
                snapshot.history,
                to: packageDirectory.appendingPathComponent("recognition-history.jsonl")
            )

            if let pinyin = snapshot.pinyin {
                try fileManager.createDirectory(
                    at: pinyinDirectory,
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(
                    at: pinyin.sourceURL,
                    to: pinyinDirectory.appendingPathComponent(
                        SharedPinyinUserDataStore.snapshotFileName
                    )
                )
            }

            var copiedRecordings = 0
            for recording in snapshot.recordings {
                guard PortablePath.isSafeFileName(recording.fileName),
                      fileManager.fileExists(atPath: recording.sourceURL.path) else {
                    throw PortableDataError.missingRecording(recording.fileName)
                }
                let destination = recordingsDirectory.appendingPathComponent(
                    recording.fileName
                )
                try fileManager.copyItem(at: recording.sourceURL, to: destination)
                copiedRecordings += 1
            }

            let counts = PortableDataCounts(
                hotwords: snapshot.hotwords.count,
                quickPhrases: snapshot.quickPhrases.count,
                recognitionHistory: snapshot.history.count,
                recordings: copiedRecordings,
                pinyinEntries: snapshot.pinyin?.entryCount ?? 0
            )
            let readme = PortableReadme.make(
                exportedAt: snapshot.exportedAt,
                appVersion: snapshot.appVersion,
                counts: counts,
                credentialsIncluded: snapshot.credentials != nil,
                pinyinIncluded: snapshot.pinyin != nil
            )
            try Data(readme.utf8).write(
                to: packageDirectory.appendingPathComponent("README.md"),
                options: .atomic
            )

            let descriptors = try describeFiles(in: packageDirectory)
            let manifest = PortableManifest(
                format: "agenboard-portable-data",
                schemaVersion: 1,
                exportedAt: snapshot.exportedAt,
                appVersion: snapshot.appVersion,
                buildNumber: snapshot.buildNumber,
                counts: counts,
                credentialsIncluded: snapshot.credentials != nil,
                files: descriptors
            )
            try PortableJSON.prettyEncoder.encode(manifest).write(
                to: packageDirectory.appendingPathComponent("manifest.json"),
                options: .atomic
            )

            let archiveURL = taskDirectory.appendingPathComponent(
                "AgenBoard-Export-\(PortableDate.fileNameStamp(snapshot.exportedAt)).zip"
            )
            try fileManager.zipItem(
                at: packageDirectory,
                to: archiveURL,
                shouldKeepParent: false,
                compressionMethod: .deflate
            )
            try fileManager.removeItem(at: packageDirectory)
            return archiveURL
        } catch {
            try? fileManager.removeItem(at: taskDirectory)
            throw error
        }
    }

    private static func writeJSONLines<T: Encodable>(
        _ values: [T],
        to url: URL
    ) throws {
        var output = Data()
        for value in values {
            output.append(try PortableJSON.lineEncoder.encode(value))
            output.append(0x0A)
        }
        try output.write(to: url, options: .atomic)
    }

    private static func describeFiles(in root: URL) throws -> [PortableFileDescriptor] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw PortableDataError.cannotCreateArchive("无法枚举导出文件。")
        }

        var descriptors: [PortableFileDescriptor] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                continue
            }
            let path = PortablePath.relativePath(of: url, under: root)
            descriptors.append(
                PortableFileDescriptor(
                    path: path,
                    byteCount: Int64(values.fileSize ?? 0),
                    sha256: try PortableHash.sha256(of: url)
                )
            )
        }
        return descriptors.sorted { $0.path < $1.path }
    }
}

private enum PortablePackageReader {
    private static let maximumEntryCount = 10_000
    private static let maximumUncompressedBytes: UInt64 = 4 * 1_024 * 1_024 * 1_024

    static func read(
        archiveURL: URL,
        workDirectory: URL,
        sourceFileName: String
    ) throws -> PortableImportPayload {
        let fileManager = FileManager.default
        let archive: Archive
        do {
            archive = try Archive(url: archiveURL, accessMode: .read)
        } catch {
            throw PortableDataError.invalidArchive("无法打开 ZIP：\(error.localizedDescription)")
        }

        let entries = Array(archive)
        guard entries.count <= maximumEntryCount else {
            throw PortableDataError.invalidArchive("ZIP 内文件数量过多。")
        }

        var totalSize: UInt64 = 0
        for entry in entries {
            guard PortablePath.isSafeArchivePath(entry.path), entry.type != .symlink else {
                throw PortableDataError.invalidArchive("ZIP 包含不安全路径：\(entry.path)")
            }
            let (sum, overflow) = totalSize.addingReportingOverflow(entry.uncompressedSize)
            guard !overflow, sum <= maximumUncompressedBytes else {
                throw PortableDataError.invalidArchive("ZIP 解压后超过 4 GB 限制。")
            }
            totalSize = sum
        }

        let extractionDirectory = workDirectory.appendingPathComponent(
            "extracted",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: extractionDirectory,
            withIntermediateDirectories: true
        )
        do {
            try fileManager.unzipItem(at: archiveURL, to: extractionDirectory)
        } catch {
            throw PortableDataError.invalidArchive("ZIP 解压失败：\(error.localizedDescription)")
        }

        let packageRoot = try findPackageRoot(in: extractionDirectory)
        let manifest: PortableManifest = try decodeJSON(
            at: packageRoot.appendingPathComponent("manifest.json")
        )
        guard manifest.format == "agenboard-portable-data" else {
            throw PortableDataError.invalidFormat("这不是 AgenBoard 可移植数据包。")
        }
        guard manifest.schemaVersion == 1 else {
            throw PortableDataError.unsupportedVersion(manifest.schemaVersion)
        }

        let preferences: PortablePreferencesDocument = try decodeJSON(
            at: packageRoot.appendingPathComponent("preferences.json")
        )
        let credentials: PortableCredentialsDocument?
        if manifest.credentialsIncluded {
            let document: PortableCredentialsDocument = try decodeJSON(
                at: packageRoot.appendingPathComponent("credentials.json")
            )
            guard document.format == "agenboard-credentials",
                  document.schemaVersion == 1,
                  !document.aliyunApiKey.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ).isEmpty else {
                throw PortableDataError.invalidFormat("credentials.json 格式或内容不正确。")
            }
            credentials = document
        } else {
            credentials = nil
        }
        let hotwordDocument: PortableHotwordsDocument = try decodeJSON(
            at: packageRoot.appendingPathComponent("hotwords.json")
        )
        let quickPhraseDocument: PortableQuickPhrasesDocument = try decodeJSON(
            at: packageRoot.appendingPathComponent("quick-phrases.json")
        )
        guard preferences.format == "agenboard-preferences",
              preferences.schemaVersion == 1,
              hotwordDocument.format == "agenboard-hotwords",
              hotwordDocument.schemaVersion == 1,
              quickPhraseDocument.format == "agenboard-quick-phrases",
              quickPhraseDocument.schemaVersion == 1 else {
            throw PortableDataError.invalidFormat("数据子文件格式或版本不正确。")
        }

        var warnings = try checksumWarnings(
            manifest: manifest,
            packageRoot: packageRoot
        )
        if credentials != nil {
            warnings.append("此数据包包含明文阿里云 API Key，导入后会保存到本机钥匙串。")
        }
        let pinyinCandidateURL = packageRoot
            .appendingPathComponent("pinyin", isDirectory: true)
            .appendingPathComponent(SharedPinyinUserDataStore.snapshotFileName)
        let pinyinSnapshotURL: URL?
        let pinyinEntryCount: Int
        if fileManager.fileExists(atPath: pinyinCandidateURL.path) {
            do {
                pinyinEntryCount = try SharedPinyinUserDataStore.validateSnapshot(
                    at: pinyinCandidateURL
                )
                pinyinSnapshotURL = pinyinCandidateURL
            } catch {
                throw PortableDataError.invalidFormat(
                    "拼音学习快照无效：\(error.localizedDescription)"
                )
            }
        } else {
            pinyinEntryCount = 0
            pinyinSnapshotURL = nil
            warnings.append("此数据包未包含拼音学习记录；导入时会保留当前设备已有的拼音偏好。")
        }
        let hotwords = sanitizeHotwords(hotwordDocument.hotwords, warnings: &warnings)
        let quickPhrases = sanitizeQuickPhrases(
            quickPhraseDocument.quickPhrases,
            warnings: &warnings
        )
        let portableHistory = try decodeJSONLines(
            PortableRecognitionRecord.self,
            at: packageRoot.appendingPathComponent("recognition-history.jsonl")
        )
        let recordingsDirectory = packageRoot.appendingPathComponent(
            "recordings",
            isDirectory: true
        )
        let history = sanitizeHistory(
            portableHistory,
            recordingsDirectory: recordingsDirectory,
            warnings: &warnings
        )
        let actualCounts = PortableDataCounts(
            hotwords: hotwords.count,
            quickPhrases: quickPhrases.count,
            recognitionHistory: history.count,
            recordings: history.filter(\.hasRecording).count,
            pinyinEntries: pinyinEntryCount
        )
        if actualCounts != manifest.counts {
            warnings.append("数据内容数量与 manifest.json 不同，预览已按实际可导入内容计算。")
        }

        return PortableImportPayload(
            sourceFileName: sourceFileName,
            workDirectory: workDirectory,
            manifest: manifest,
            counts: actualCounts,
            preferences: preferences,
            credentials: credentials,
            hotwords: hotwords,
            quickPhrases: quickPhrases,
            history: history,
            recordingsDirectory: recordingsDirectory,
            pinyinSnapshotURL: pinyinSnapshotURL,
            warnings: warnings
        )
    }

    private static func findPackageRoot(in extractionDirectory: URL) throws -> URL {
        let fileManager = FileManager.default
        let directManifest = extractionDirectory.appendingPathComponent("manifest.json")
        if fileManager.fileExists(atPath: directManifest.path) {
            return extractionDirectory
        }

        let children = try fileManager.contentsOfDirectory(
            at: extractionDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let roots = children.filter {
            fileManager.fileExists(
                atPath: $0.appendingPathComponent("manifest.json").path
            )
        }
        guard roots.count == 1, let root = roots.first else {
            throw PortableDataError.invalidFormat("ZIP 根目录中没有唯一的 manifest.json。")
        }
        return root
    }

    private static func decodeJSON<T: Decodable>(at url: URL) throws -> T {
        do {
            return try PortableJSON.decoder.decode(T.self, from: Data(contentsOf: url))
        } catch {
            throw PortableDataError.invalidJSON(url.lastPathComponent, error.localizedDescription)
        }
    }

    private static func decodeJSONLines<T: Decodable>(
        _ type: T.Type,
        at url: URL
    ) throws -> [T] {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw PortableDataError.invalidJSON(url.lastPathComponent, error.localizedDescription)
        }

        var values: [T] = []
        for (index, line) in text.split(whereSeparator: \.isNewline).enumerated() {
            do {
                values.append(
                    try PortableJSON.decoder.decode(T.self, from: Data(line.utf8))
                )
            } catch {
                throw PortableDataError.invalidJSON(
                    "\(url.lastPathComponent) 第 \(index + 1) 行",
                    error.localizedDescription
                )
            }
        }
        return values
    }

    private static func checksumWarnings(
        manifest: PortableManifest,
        packageRoot: URL
    ) throws -> [String] {
        var warnings: [String] = []
        for descriptor in manifest.files {
            guard PortablePath.isSafeArchivePath(descriptor.path) else {
                throw PortableDataError.invalidArchive("清单包含不安全路径。")
            }
            let url = packageRoot.appendingPathComponent(descriptor.path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                warnings.append("清单中的文件缺失：\(descriptor.path)")
                continue
            }
            let digest = try PortableHash.sha256(of: url)
            if digest != descriptor.sha256.lowercased() {
                warnings.append(
                    "文件已经修改：\(descriptor.path)。如果由你或 AI 编辑，可以继续导入。"
                )
            }
        }
        return warnings
    }

    private static func sanitizeHotwords(
        _ candidates: [PortableHotword],
        warnings: inout [String]
    ) -> [HotwordEntry] {
        var ids = Set<UUID>()
        var terms = Set<String>()
        var output: [HotwordEntry] = []
        var skipped = 0

        for candidate in candidates {
            guard let term = HotwordLibraryStorage.normalizedTerm(candidate.term),
                  ids.insert(candidate.id).inserted,
                  terms.insert(HotwordLibraryStorage.comparisonKey(term)).inserted else {
                skipped += 1
                continue
            }
            output.append(
                HotwordEntry(
                    id: candidate.id,
                    term: term,
                    isPinned: candidate.pinned,
                    isEnabled: candidate.enabled,
                    lastUsedAt: candidate.lastUsedAt,
                    createdAt: candidate.createdAt
                )
            )
        }
        if skipped > 0 {
            warnings.append("已忽略 \(skipped) 个无效或重复热词。")
        }
        return output
    }

    private static func sanitizeQuickPhrases(
        _ candidates: [PortableQuickPhrase],
        warnings: inout [String]
    ) -> [SharedQuickPhrase] {
        var ids = Set<UUID>()
        var contentKeys = Set<String>()
        var output: [SharedQuickPhrase] = []
        var skipped = 0

        for candidate in candidates {
            let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let content = candidate.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let contentKey = content.precomposedStringWithCanonicalMapping.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard !title.isEmpty,
                  !content.isEmpty,
                  title.count <= 64,
                  content.count <= 500,
                  ids.insert(candidate.id).inserted,
                  contentKeys.insert(contentKey).inserted else {
                skipped += 1
                continue
            }
            output.append(
                SharedQuickPhrase(
                    id: candidate.id,
                    title: title,
                    content: content,
                    isEnabled: candidate.enabled,
                    createdAt: candidate.createdAt
                )
            )
        }
        if skipped > 0 {
            warnings.append("已忽略 \(skipped) 条无效或重复快捷短语。")
        }
        return output
    }

    private static func sanitizeHistory(
        _ candidates: [PortableRecognitionRecord],
        recordingsDirectory: URL,
        warnings: inout [String]
    ) -> [RecognitionHistoryItem] {
        var ids = Set<UUID>()
        var fileNames = Set<String>()
        var output: [RecognitionHistoryItem] = []
        var skipped = 0
        var textOnly = 0
        var missingRecordings = 0

        for candidate in candidates {
            guard ids.insert(candidate.id).inserted,
                  candidate.audio.durationSeconds >= 0,
                  candidate.audio.sizeBytes >= 0 else {
                skipped += 1
                continue
            }

            let fileName = candidate.audio.file.flatMap(
                PortablePath.recordingFileName(from:)
            )
            var recordingAvailable = false
            if candidate.audio.includesFile,
               let fileName,
               fileNames.insert(fileName).inserted {
                recordingAvailable = FileManager.default.fileExists(
                    atPath: recordingsDirectory.appendingPathComponent(fileName).path
                )
                if !recordingAvailable {
                    missingRecordings += 1
                }
            } else if candidate.audio.includesFile {
                missingRecordings += 1
            }

            if !recordingAvailable {
                textOnly += 1
            }
            let item = candidate.item(
                recordingAvailable: recordingAvailable,
                fileName: fileName
            )
            output.append(item)
        }
        if skipped > 0 {
            warnings.append("已忽略 \(skipped) 条无效或重复的识别历史。")
        }
        if textOnly > 0 {
            warnings.append("\(textOnly) 条识别历史未附原始录音，转写文本仍会正常导入。")
        }
        if missingRecordings > 0 {
            warnings.append("\(missingRecordings) 条历史声明包含录音但文件缺失，已按纯文本历史导入。")
        }
        return output.sorted { $0.createdAt > $1.createdAt }
    }
}

private enum PortableJSON {
    static var prettyEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var lineEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = PortableDate.parse(value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "无法解析 ISO 8601 时间：\(value)"
            )
        }
        return decoder
    }
}

private enum PortableDate {
    static func parse(_ value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func fileNameStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: date)
    }
}

private enum PortablePath {
    static func isSafeFileName(_ value: String) -> Bool {
        !value.isEmpty
            && value == URL(fileURLWithPath: value).lastPathComponent
            && !value.contains("/")
            && !value.contains("\\")
    }

    static func isSafeArchivePath(_ value: String) -> Bool {
        var candidate = value
        if candidate.hasSuffix("/") {
            candidate.removeLast()
        }
        guard !candidate.isEmpty,
              !candidate.hasPrefix("/"),
              !candidate.contains("\\"),
              !candidate.contains("\0") else {
            return false
        }
        return candidate.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    static func recordingFileName(from value: String) -> String? {
        guard isSafeArchivePath(value), value.hasPrefix("recordings/") else {
            return nil
        }
        let components = value.split(separator: "/")
        guard components.count == 2 else {
            return nil
        }
        let fileName = String(components[1])
        guard isSafeFileName(fileName),
              URL(fileURLWithPath: fileName).pathExtension.lowercased() == "m4a" else {
            return nil
        }
        return fileName
    }

    static func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let start = path.index(path.startIndex, offsetBy: rootPath.count)
        return String(path[start...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

private enum PortableHash {
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private enum PortableReadme {
    static func make(
        exportedAt: Date,
        appVersion: String,
        counts: PortableDataCounts,
        credentialsIncluded: Bool,
        pinyinIncluded: Bool
    ) -> String {
        let credentialDescription = credentialsIncluded
            ? "- `credentials.json`：用户明确选择导出的明文阿里云 API Key。"
            : "- 本数据包未包含 API Key；导入后沿用目标设备钥匙串中的凭证。"
        let recordingDescription = counts.recordings > 0
            ? "- `recordings/`：用户明确选择导出的标准 M4A 原始录音，通过历史记录中的 `audio.file` 关联。"
            : "- `recordings/`：本次未包含原始录音；历史中的 `audio.included` 为 `false`，转写文本不受影响。"
        let pinyinDescription = pinyinIncluded
            ? "- `pinyin/rime_ice.userdb.txt`：Rime 原生 UTF-8 文本快照，包含拼音编码、候选文字及用户学习得到的次数、权重和时间数据。"
            : "- 本数据包没有可用的拼音学习快照；导入时不会清除目标设备已有的拼音偏好。"
        return """
        # AgenBoard 可移植用户数据

        这是由用户主动导出的、面向人类、AI 和其他应用的开放数据包。

        - 格式版本：1
        - AgenBoard 版本：\(appVersion)
        - 导出时间：\(PortableDate.string(exportedAt))
        - 热词：\(counts.hotwords)
        - 快捷短语：\(counts.quickPhrases)
        - 识别历史：\(counts.recognitionHistory)
        - 录音：\(counts.recordings)
        - 拼音学习记录：\(counts.pinyinEntries)

        ## 文件

        - `manifest.json`：格式版本、数量、文件清单与 SHA-256 校验值。
        - `preferences.json`：识别和键盘偏好；不包含 API Key。
        - `hotwords.json`：热词、启用状态、置顶状态和使用时间。
        - `quick-phrases.json`：快捷短语、顺序和启用状态。
        - `recognition-history.jsonl`：每行一条识别历史，适合 AI 和脚本流式处理；转写文本始终包含。
        \(pinyinDescription)
        \(recordingDescription)
        \(credentialDescription)

        ## 编辑与迁移

        所有 JSON 字段均使用可读英文名称，时间采用 ISO 8601，ID 使用 UUID。拼音学习数据沿用 Rime 的可读 TSV 快照格式。
        可以用文本编辑器、脚本或 AI 修改 JSON 或拼音快照后重新压缩为 ZIP 并导回 AgenBoard。
        修改文件后无需更新 manifest 中的校验值；导入时会提示文件已修改，但只要结构有效仍可继续。

        智能合并以稳定 ID 判断同一条数据；没有相同 ID 时，热词按规范化文字去重，快捷短语按内容去重；拼音学习记录由 Rime 原生合并。
        完全替换会以此数据包覆盖当前热词、短语、偏好、历史、包内录音和包内拼音学习记录。未附录音的历史仍可作为纯文本历史导入。

        ## 隐私

        转写文本始终包含；原始录音只有用户在导出页明确开启时才会加入。只有用户明确开启时，阿里云 API Key 才会以明文写入 `credentials.json`。钥匙串本身、缓存、临时文件、画中画状态和键盘运行状态不会导出。
        """
    }
}

enum PortableDataError: LocalizedError {
    case cannotCreateArchive(String)
    case cannotReadSelectedFile(String)
    case invalidArchive(String)
    case invalidFormat(String)
    case unsupportedVersion(Int)
    case invalidJSON(String, String)
    case missingRecording(String)

    var errorDescription: String? {
        switch self {
        case .cannotCreateArchive(let message):
            return "导出包创建失败：\(message)"
        case .cannotReadSelectedFile(let message):
            return "无法读取所选文件：\(message)"
        case .invalidArchive(let message):
            return "导入包无效：\(message)"
        case .invalidFormat(let message):
            return message
        case .unsupportedVersion(let version):
            return "暂不支持格式版本 \(version)，请升级 AgenBoard。"
        case .invalidJSON(let file, let message):
            return "\(file) 无法解析：\(message)"
        case .missingRecording(let fileName):
            return "识别历史对应的录音不存在：\(fileName)"
        }
    }
}
