@preconcurrency import AVFoundation
import Combine
import Foundation

enum RecognitionHotwordMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case withHotwords
    case withoutHotwords

    var id: String { rawValue }

    var title: String {
        switch self {
        case .withHotwords:
            return "传入热词"
        case .withoutHotwords:
            return "不传热词"
        }
    }
}

enum RecognitionPreferences {
    static let useHotwordsKey = "recognitionUsesHotwordsV1"
    nonisolated(unsafe) static let defaults =
        UserDefaults(suiteName: SharedCommandStore.appGroupIdentifier) ?? .standard

    static var usesHotwords: Bool {
        guard defaults.object(forKey: useHotwordsKey) != nil else {
            return true
        }
        return defaults.bool(forKey: useHotwordsKey)
    }
}

struct RecognitionBenchmarkResult: Codable, Equatable, Identifiable, Sendable {
    let provider: SpeechRecognitionProvider
    let mode: RecognitionHotwordMode
    let completedAt: Date
    let transcript: String
    let elapsed: TimeInterval
    let configuredHotwordCount: Int
    let matchedTerms: [String]
    let words: [SpeechRecognitionWord]
    let fileMetrics: AliyunFileRecognitionMetrics?
    let realtimeMetrics: AliyunRealtimeRecognitionMetrics?

    var id: String {
        "\(provider.rawValue)-\(mode.rawValue)"
    }
}

struct RecognitionHistoryItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let audioFileName: String
    let duration: TimeInterval
    let fileSize: Int64
    var originalMode: RecognitionHotwordMode?
    var originalProvider: SpeechRecognitionProvider?
    var transcriptWithHotwords: String?
    var transcriptWithoutHotwords: String?
    var withHotwordsElapsed: TimeInterval?
    var withoutHotwordsElapsed: TimeInterval?
    var withHotwordsConfiguredCount: Int?
    var withHotwordsMatchedTerms: [String]?
    var withoutHotwordsMatchedTerms: [String]?
    var withHotwordsProvider: SpeechRecognitionProvider?
    var withoutHotwordsProvider: SpeechRecognitionProvider?
    var withHotwordsWords: [SpeechRecognitionWord]?
    var withoutHotwordsWords: [SpeechRecognitionWord]?
    var withHotwordsRealtimeMetrics: AliyunRealtimeRecognitionMetrics? = nil
    var withoutHotwordsRealtimeMetrics: AliyunRealtimeRecognitionMetrics? = nil
    var benchmarkResults: [RecognitionBenchmarkResult]? = nil
    var lastError: String?
    var lastErrorMode: RecognitionHotwordMode?
    var lastErrorProvider: SpeechRecognitionProvider?
    var recordingAvailable: Bool? = nil

    var hasRecording: Bool {
        recordingAvailable ?? true
    }

    func transcript(for mode: RecognitionHotwordMode) -> String? {
        switch mode {
        case .withHotwords:
            return transcriptWithHotwords
        case .withoutHotwords:
            return transcriptWithoutHotwords
        }
    }

    var availableBenchmarkResults: [RecognitionBenchmarkResult] {
        benchmarkResults ?? []
    }

    func elapsed(for mode: RecognitionHotwordMode) -> TimeInterval? {
        switch mode {
        case .withHotwords:
            return withHotwordsElapsed
        case .withoutHotwords:
            return withoutHotwordsElapsed
        }
    }

    func matchedTerms(for mode: RecognitionHotwordMode) -> [String] {
        switch mode {
        case .withHotwords:
            return withHotwordsMatchedTerms ?? []
        case .withoutHotwords:
            return withoutHotwordsMatchedTerms ?? []
        }
    }

    func provider(for mode: RecognitionHotwordMode) -> SpeechRecognitionProvider? {
        switch mode {
        case .withHotwords:
            return withHotwordsProvider
        case .withoutHotwords:
            return withoutHotwordsProvider
        }
    }

    func words(for mode: RecognitionHotwordMode) -> [SpeechRecognitionWord] {
        switch mode {
        case .withHotwords:
            return withHotwordsWords ?? []
        case .withoutHotwords:
            return withoutHotwordsWords ?? []
        }
    }

    func realtimeMetrics(
        for mode: RecognitionHotwordMode
    ) -> AliyunRealtimeRecognitionMetrics? {
        switch mode {
        case .withHotwords:
            return withHotwordsRealtimeMetrics
        case .withoutHotwords:
            return withoutHotwordsRealtimeMetrics
        }
    }
}

struct ArchivedRecognitionRecording {
    let id: UUID
    let audioURL: URL
}

@MainActor
final class RecognitionHistoryStore: ObservableObject {
    @Published private(set) var items: [RecognitionHistoryItem] = []
    @Published private(set) var storageMessage = ""

    private let fileManager: FileManager
    private let rootDirectory: URL
    private let recordingsDirectory: URL
    private let metadataURL: URL
    private var hasLoadedHistory = false
    private var canAccessStorage = true
    private static let migratedLegacyResultIDKey = "recognitionHistoryMigratedResultIDV1"

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        rootDirectory = applicationSupport.appendingPathComponent(
            "AgenBoard/RecognitionHistory",
            isDirectory: true
        )
        recordingsDirectory = rootDirectory.appendingPathComponent("Recordings", isDirectory: true)
        metadataURL = rootDirectory.appendingPathComponent("history.json")

        do {
            try fileManager.createDirectory(
                at: recordingsDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            storageMessage = "历史记录目录创建失败：\(error.localizedDescription)"
            canAccessStorage = false
            return
        }
    }

    func loadIfNeeded() {
        guard !hasLoadedHistory, canAccessStorage else {
            return
        }
        hasLoadedHistory = true

        var needsIndexRepair = false
        do {
            items = try loadItems()
        } catch {
            items = []
            needsIndexRepair = true
            storageMessage = "历史索引已损坏，正在从音频恢复。"
        }

        var changed = removeMissingItems() || needsIndexRepair
        changed = recoverOrphanedRecordings() || changed
        changed = migrateLegacyTemporaryRecordings() || changed
        let attachedLegacyTranscript = attachLatestLegacyTranscriptIfPossible()
        changed = attachedLegacyTranscript || changed
        sortItems()

        if changed {
            do {
                try persist()
                if attachedLegacyTranscript,
                   let latestResult = SharedCommandStore.latestRecognitionResult() {
                    RecognitionPreferences.defaults.set(
                        latestResult.id,
                        forKey: Self.migratedLegacyResultIDKey
                    )
                    RecognitionPreferences.defaults.synchronize()
                }
            } catch {
                storageMessage = "历史索引写入失败：\(error.localizedDescription)"
            }
        }
    }

    var latestItem: RecognitionHistoryItem? {
        items.first
    }

    func item(id: UUID) -> RecognitionHistoryItem? {
        items.first { $0.id == id }
    }

    func audioURL(for item: RecognitionHistoryItem) -> URL {
        recordingsDirectory.appendingPathComponent(item.audioFileName)
    }

    func archiveRecording(
        at sourceURL: URL,
        duration: TimeInterval,
        originalMode: RecognitionHotwordMode,
        originalProvider: SpeechRecognitionProvider
    ) throws -> ArchivedRecognitionRecording {
        loadIfNeeded()
        let details = try inspectAudio(at: sourceURL)
        let id = UUID()
        let fileName = "\(id.uuidString).m4a"
        let destinationURL = recordingsDirectory.appendingPathComponent(fileName)

        try movePreservingRecording(from: sourceURL, to: destinationURL)

        let item = RecognitionHistoryItem(
            id: id,
            createdAt: Date(),
            audioFileName: fileName,
            duration: details.duration > 0 ? details.duration : duration,
            fileSize: details.fileSize,
            originalMode: originalMode,
            originalProvider: originalProvider,
            transcriptWithHotwords: nil,
            transcriptWithoutHotwords: nil,
            withHotwordsElapsed: nil,
            withoutHotwordsElapsed: nil,
            withHotwordsConfiguredCount: nil,
            withHotwordsMatchedTerms: nil,
            withoutHotwordsMatchedTerms: nil,
            withHotwordsProvider: nil,
            withoutHotwordsProvider: nil,
            withHotwordsWords: nil,
            withoutHotwordsWords: nil,
            lastError: nil,
            lastErrorMode: nil,
            lastErrorProvider: nil
        )
        items.insert(item, at: 0)

        do {
            try persist()
            storageMessage = ""
        } catch {
            storageMessage = "录音已保留，但历史索引写入失败：\(error.localizedDescription)"
        }

        return ArchivedRecognitionRecording(id: id, audioURL: destinationURL)
    }

    func storeTranscription(
        itemID: UUID,
        mode: RecognitionHotwordMode,
        transcript: String,
        elapsed: TimeInterval,
        configuredHotwordCount: Int,
        matchedTerms: [String],
        provider: SpeechRecognitionProvider,
        words: [SpeechRecognitionWord],
        fileMetrics: AliyunFileRecognitionMetrics? = nil,
        realtimeMetrics: AliyunRealtimeRecognitionMetrics? = nil
    ) throws {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else {
            throw RecognitionHistoryError.missingItem
        }

        switch mode {
        case .withHotwords:
            items[index].transcriptWithHotwords = transcript
            items[index].withHotwordsElapsed = elapsed
            items[index].withHotwordsConfiguredCount = configuredHotwordCount
            items[index].withHotwordsMatchedTerms = matchedTerms
            items[index].withHotwordsProvider = provider
            items[index].withHotwordsWords = words
            items[index].withHotwordsRealtimeMetrics = realtimeMetrics
        case .withoutHotwords:
            items[index].transcriptWithoutHotwords = transcript
            items[index].withoutHotwordsElapsed = elapsed
            items[index].withoutHotwordsMatchedTerms = matchedTerms
            items[index].withoutHotwordsProvider = provider
            items[index].withoutHotwordsWords = words
            items[index].withoutHotwordsRealtimeMetrics = realtimeMetrics
        }

        var benchmarkResults = items[index].benchmarkResults ?? []
        benchmarkResults.removeAll {
            $0.provider == provider && $0.mode == mode
        }
        benchmarkResults.append(
            RecognitionBenchmarkResult(
                provider: provider,
                mode: mode,
                completedAt: Date(),
                transcript: transcript,
                elapsed: elapsed,
                configuredHotwordCount: configuredHotwordCount,
                matchedTerms: matchedTerms,
                words: words,
                fileMetrics: fileMetrics,
                realtimeMetrics: realtimeMetrics
            )
        )
        items[index].benchmarkResults = benchmarkResults

        items[index].lastError = nil
        items[index].lastErrorMode = nil
        items[index].lastErrorProvider = nil
        try persist()
        storageMessage = ""
    }

    func storeFailure(
        itemID: UUID,
        mode: RecognitionHotwordMode,
        provider: SpeechRecognitionProvider,
        message: String
    ) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else {
            return
        }

        items[index].lastError = message
        items[index].lastErrorMode = mode
        items[index].lastErrorProvider = provider

        do {
            try persist()
            storageMessage = ""
        } catch {
            storageMessage = "识别错误记录保存失败：\(error.localizedDescription)"
        }
    }

    func delete(at offsets: IndexSet) throws {
        loadIfNeeded()
        let removedItems = offsets.map { items[$0] }
        for item in removedItems where item.hasRecording {
            try? fileManager.removeItem(at: audioURL(for: item))
        }
        for index in offsets.sorted(by: >) {
            items.remove(at: index)
        }
        try persist()
    }

    func delete(itemID: UUID) throws {
        loadIfNeeded()
        guard let index = items.firstIndex(where: { $0.id == itemID }) else {
            return
        }
        try delete(at: IndexSet(integer: index))
    }

    func importPortableItems(
        _ importedItems: [RecognitionHistoryItem],
        recordingsDirectory importedRecordingsDirectory: URL,
        mode: PortableImportMode
    ) throws {
        loadIfNeeded()

        let currentItems = items
        let finalItems: [RecognitionHistoryItem]
        switch mode {
        case .replace:
            finalItems = importedItems
        case .merge:
            var merged = currentItems
            for imported in importedItems {
                if let index = merged.firstIndex(where: { $0.id == imported.id }) {
                    merged[index] = mergeHistoryItem(
                        current: merged[index],
                        imported: imported
                    )
                } else {
                    merged.append(imported)
                }
            }
            finalItems = merged
        }

        let parentDirectory = rootDirectory.deletingLastPathComponent()
        let stagingDirectory = parentDirectory.appendingPathComponent(
            "RecognitionHistory.importing-\(UUID().uuidString)",
            isDirectory: true
        )
        let stagingRecordingsDirectory = stagingDirectory.appendingPathComponent(
            "Recordings",
            isDirectory: true
        )

        try fileManager.createDirectory(
            at: stagingRecordingsDirectory,
            withIntermediateDirectories: true
        )

        do {
            let currentIDs = Set(currentItems.map(\.id))
            let importedByID = Dictionary(
                uniqueKeysWithValues: importedItems.map { ($0.id, $0) }
            )

            for item in finalItems {
                guard item.hasRecording else {
                    continue
                }
                let currentURL = recordingsDirectory.appendingPathComponent(
                    item.audioFileName
                )
                let importedFileName = importedByID[item.id]?.audioFileName
                let importedURL = importedFileName.map {
                    importedRecordingsDirectory.appendingPathComponent($0)
                }

                let sourceURL: URL
                if mode == .merge,
                   currentIDs.contains(item.id),
                   fileManager.fileExists(atPath: currentURL.path) {
                    sourceURL = currentURL
                } else if let importedURL,
                          fileManager.fileExists(atPath: importedURL.path) {
                    sourceURL = importedURL
                } else if fileManager.fileExists(atPath: currentURL.path) {
                    sourceURL = currentURL
                } else {
                    throw RecognitionHistoryError.missingImportedRecording(
                        item.audioFileName
                    )
                }

                _ = try inspectAudio(at: sourceURL)
                let destinationURL = stagingRecordingsDirectory.appendingPathComponent(
                    item.audioFileName
                )
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            }

            try persist(
                finalItems.sorted { $0.createdAt > $1.createdAt },
                to: stagingDirectory.appendingPathComponent("history.json")
            )

            if fileManager.fileExists(atPath: rootDirectory.path) {
                let backupName = "RecognitionHistory.backup-\(UUID().uuidString)"
                _ = try fileManager.replaceItemAt(
                    rootDirectory,
                    withItemAt: stagingDirectory,
                    backupItemName: backupName
                )
                try? fileManager.removeItem(
                    at: parentDirectory.appendingPathComponent(backupName)
                )
            } else {
                try fileManager.moveItem(at: stagingDirectory, to: rootDirectory)
            }

            items = finalItems.sorted { $0.createdAt > $1.createdAt }
            hasLoadedHistory = true
            canAccessStorage = true
            storageMessage = ""
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            throw error
        }
    }

    private func loadItems() throws -> [RecognitionHistoryItem] {
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return []
        }

        let data = try Data(contentsOf: metadataURL)
        return try JSONDecoder().decode([RecognitionHistoryItem].self, from: data)
    }

    private func persist() throws {
        try persist(items, to: metadataURL)
    }

    private func persist(_ values: [RecognitionHistoryItem], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(values)
        try data.write(to: url, options: .atomic)
    }

    private func mergeHistoryItem(
        current: RecognitionHistoryItem,
        imported: RecognitionHistoryItem
    ) -> RecognitionHistoryItem {
        let recording = mergedRecordingItem(current: current, imported: imported)
        return RecognitionHistoryItem(
            id: current.id,
            createdAt: current.createdAt,
            audioFileName: recording.audioFileName,
            duration: recording.duration,
            fileSize: recording.fileSize,
            originalMode: imported.originalMode ?? current.originalMode,
            originalProvider: imported.originalProvider ?? current.originalProvider,
            transcriptWithHotwords:
                imported.transcriptWithHotwords ?? current.transcriptWithHotwords,
            transcriptWithoutHotwords:
                imported.transcriptWithoutHotwords ?? current.transcriptWithoutHotwords,
            withHotwordsElapsed:
                imported.withHotwordsElapsed ?? current.withHotwordsElapsed,
            withoutHotwordsElapsed:
                imported.withoutHotwordsElapsed ?? current.withoutHotwordsElapsed,
            withHotwordsConfiguredCount:
                imported.withHotwordsConfiguredCount ?? current.withHotwordsConfiguredCount,
            withHotwordsMatchedTerms:
                imported.withHotwordsMatchedTerms ?? current.withHotwordsMatchedTerms,
            withoutHotwordsMatchedTerms:
                imported.withoutHotwordsMatchedTerms ?? current.withoutHotwordsMatchedTerms,
            withHotwordsProvider:
                imported.withHotwordsProvider ?? current.withHotwordsProvider,
            withoutHotwordsProvider:
                imported.withoutHotwordsProvider ?? current.withoutHotwordsProvider,
            withHotwordsWords:
                imported.withHotwordsWords ?? current.withHotwordsWords,
            withoutHotwordsWords:
                imported.withoutHotwordsWords ?? current.withoutHotwordsWords,
            withHotwordsRealtimeMetrics:
                imported.withHotwordsRealtimeMetrics ?? current.withHotwordsRealtimeMetrics,
            withoutHotwordsRealtimeMetrics:
                imported.withoutHotwordsRealtimeMetrics
                    ?? current.withoutHotwordsRealtimeMetrics,
            benchmarkResults: mergeBenchmarkResults(
                current.availableBenchmarkResults,
                imported.availableBenchmarkResults
            ),
            lastError: imported.lastError ?? current.lastError,
            lastErrorMode: imported.lastErrorMode ?? current.lastErrorMode,
            lastErrorProvider: imported.lastErrorProvider ?? current.lastErrorProvider,
            recordingAvailable: recording.hasRecording
        )
    }

    private func mergeBenchmarkResults(
        _ current: [RecognitionBenchmarkResult],
        _ imported: [RecognitionBenchmarkResult]
    ) -> [RecognitionBenchmarkResult]? {
        guard !current.isEmpty || !imported.isEmpty else {
            return nil
        }
        var merged = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        for result in imported {
            if let existing = merged[result.id], existing.completedAt > result.completedAt {
                continue
            }
            merged[result.id] = result
        }
        return merged.values.sorted { lhs, rhs in
            lhs.completedAt < rhs.completedAt
        }
    }

    private func mergedRecordingItem(
        current: RecognitionHistoryItem,
        imported: RecognitionHistoryItem
    ) -> RecognitionHistoryItem {
        if current.hasRecording {
            return current
        }
        return imported
    }

    private func removeMissingItems() -> Bool {
        var changed = false
        for index in items.indices where items[index].hasRecording {
            if !fileManager.fileExists(atPath: audioURL(for: items[index]).path) {
                items[index].recordingAvailable = false
                changed = true
            }
        }
        return changed
    }

    private func recoverOrphanedRecordings() -> Bool {
        let knownFileNames = Set(items.filter(\.hasRecording).map(\.audioFileName))
        guard let urls = try? fileManager.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        var changed = false
        for url in urls where url.pathExtension.lowercased() == "m4a" {
            guard !knownFileNames.contains(url.lastPathComponent),
                  let details = try? inspectAudio(at: url) else {
                continue
            }

            let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID()
            items.append(makeMigratedItem(id: id, url: url, details: details))
            changed = true
        }
        return changed
    }

    private func migrateLegacyTemporaryRecordings() -> Bool {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: fileManager.temporaryDirectory,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        var changed = false
        for sourceURL in urls where isMigratableRecording(sourceURL) {
            guard let details = try? inspectAudio(at: sourceURL) else {
                continue
            }

            let id = UUID()
            let destinationURL = recordingsDirectory
                .appendingPathComponent("\(id.uuidString).m4a")

            do {
                try movePreservingRecording(from: sourceURL, to: destinationURL)
                items.append(makeMigratedItem(id: id, url: destinationURL, details: details))
                changed = true
            } catch {
                storageMessage = "部分旧录音迁移失败：\(error.localizedDescription)"
            }
        }
        return changed
    }

    private func attachLatestLegacyTranscriptIfPossible() -> Bool {
        guard let latestResult = SharedCommandStore.latestRecognitionResult(),
              latestResult.createdAt > 0,
              RecognitionPreferences.defaults.string(
                forKey: Self.migratedLegacyResultIDKey
              ) != latestResult.id else {
            return false
        }

        let resultDate = Date(timeIntervalSince1970: latestResult.createdAt)
        let candidates = items.indices.filter {
            items[$0].transcriptWithHotwords == nil && items[$0].transcriptWithoutHotwords == nil
        }
        guard let index = candidates.min(by: {
            abs(items[$0].createdAt.timeIntervalSince(resultDate))
                < abs(items[$1].createdAt.timeIntervalSince(resultDate))
        }), abs(items[index].createdAt.timeIntervalSince(resultDate)) <= 5 * 60 else {
            return false
        }

        let hotwords = HotwordLibraryStorage.loadTerms()
        items[index].originalMode = .withHotwords
        items[index].originalProvider = .apple
        items[index].transcriptWithHotwords = latestResult.text
        items[index].withHotwordsProvider = .apple
        items[index].withHotwordsConfiguredCount = hotwords.count
        items[index].withHotwordsMatchedTerms = HotwordTranscriptMatcher.matches(
            in: latestResult.text,
            hotwords: hotwords
        )
        return true
    }

    private func makeMigratedItem(
        id: UUID,
        url: URL,
        details: AudioDetails
    ) -> RecognitionHistoryItem {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let createdAt = values?.creationDate ?? values?.contentModificationDate ?? Date()
        return RecognitionHistoryItem(
            id: id,
            createdAt: createdAt,
            audioFileName: url.lastPathComponent,
            duration: details.duration,
            fileSize: details.fileSize,
            originalMode: nil,
            originalProvider: nil,
            transcriptWithHotwords: nil,
            transcriptWithoutHotwords: nil,
            withHotwordsElapsed: nil,
            withoutHotwordsElapsed: nil,
            withHotwordsConfiguredCount: nil,
            withHotwordsMatchedTerms: nil,
            withoutHotwordsMatchedTerms: nil,
            withHotwordsProvider: nil,
            withoutHotwordsProvider: nil,
            withHotwordsWords: nil,
            withoutHotwordsWords: nil,
            lastError: nil,
            lastErrorMode: nil,
            lastErrorProvider: nil
        )
    }

    private func inspectAudio(at url: URL) throws -> AudioDetails {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let audioFile = try AVAudioFile(forReading: url)
        let sampleRate = audioFile.processingFormat.sampleRate

        guard fileSize > 128, audioFile.length > 0, sampleRate > 0 else {
            throw RecognitionHistoryError.invalidAudio
        }

        return AudioDetails(
            duration: Double(audioFile.length) / sampleRate,
            fileSize: fileSize
        )
    }

    private func movePreservingRecording(from sourceURL: URL, to destinationURL: URL) throws {
        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            try? fileManager.removeItem(at: sourceURL)
        }
    }

    private func isMigratableRecording(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "m4a" else {
            return false
        }

        let fileName = url.lastPathComponent
        return fileName.hasPrefix("agenboard-")
            || fileName.hasPrefix("hotword-capacity-")
    }

    private func sortItems() {
        items.sort { $0.createdAt > $1.createdAt }
    }
}

enum HotwordTranscriptMatcher {
    static func matches(in transcript: String, hotwords: [String]) -> [String] {
        let transcriptKey = HotwordLibraryStorage.comparisonKey(transcript)
        return hotwords.filter {
            transcriptKey.contains(HotwordLibraryStorage.comparisonKey($0))
        }
    }
}

private struct AudioDetails {
    let duration: TimeInterval
    let fileSize: Int64
}

private enum RecognitionHistoryError: LocalizedError {
    case invalidAudio
    case missingItem
    case missingImportedRecording(String)

    var errorDescription: String? {
        switch self {
        case .invalidAudio:
            return "录音文件为空或无法读取。"
        case .missingItem:
            return "没有找到对应的历史录音。"
        case .missingImportedRecording(let fileName):
            return "导入包缺少录音：\(fileName)"
        }
    }
}
