import Foundation
import os

struct SharedRecordingSnapshot {
    let isRecording: Bool
    let isTranscribing: Bool
    let audioLevel: Double
    let decibels: Double
    let duration: Double
    let status: String
    let updatedAt: TimeInterval
}

struct SharedRecognitionResult {
    let id: String
    let text: String
    let createdAt: TimeInterval
}

struct SharedRecordingToggleRequest {
    let id: String
    let requestedAt: TimeInterval
    let shouldReturnToPreviousInterface: Bool
    let sourceHostBundleIdentifier: String?
}

enum RecordingLaunchMetrics {
    private static let logger = Logger(
        subsystem: "dev.local.agenboard",
        category: "RecordingLaunch"
    )

    static func mark(
        _ event: String,
        request: SharedRecordingToggleRequest? = nil,
        requestedAt: TimeInterval? = nil,
        detail: String = ""
    ) {
        let requestID = request?.id ?? "-"
        let start = request?.requestedAt ?? requestedAt
        let elapsed = start.map {
            String(format: "%.1f", max(0, Date().timeIntervalSince1970 - $0) * 1_000)
        } ?? "-"

        logger.notice(
            "event=\(event, privacy: .public) request=\(requestID, privacy: .public) elapsed_ms=\(elapsed, privacy: .public) detail=\(detail, privacy: .public)"
        )
    }
}

struct SharedQuickPhrase: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var content: String
    var isEnabled: Bool
    let createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        content: String,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }
}

enum SharedCommandStore {
    static let appGroupIdentifier = "group.dev.local.agenboard"
    static let recordingToggleDarwinNotificationName =
        "dev.local.agenboard.recording-toggle"
    static let maximumKeyboardQuickPhraseCount = 6
    static let defaultQuickPhrases = [
        SharedQuickPhrase(
            title: "测试文本",
            content: "AgenBoard 输入法测试",
            createdAt: Date(timeIntervalSince1970: 0)
        ),
        SharedQuickPhrase(
            title: "/new",
            content: "/new",
            createdAt: Date(timeIntervalSince1970: 1)
        ),
        SharedQuickPhrase(
            title: "/start",
            content: "/start",
            createdAt: Date(timeIntervalSince1970: 2)
        ),
        SharedQuickPhrase(
            title: "Claude Code",
            content: "Claude Code",
            createdAt: Date(timeIntervalSince1970: 3)
        )
    ]

    private static let recordingToggleRequestIDKey = "recordingToggleRequestID"
    private static let recordingToggleRequestedAtKey = "recordingToggleRequestedAt"
    private static let recordingToggleShouldReturnKey = "recordingToggleShouldReturn"
    private static let recordingToggleHostBundleIdentifierKey =
        "recordingToggleHostBundleIdentifier"
    private static let keyboardHostBundleIdentifierKey =
        "keyboardHostBundleIdentifier"
    private static let keyboardHostBundleIdentifierCapturedAtKey =
        "keyboardHostBundleIdentifierCapturedAt"
    private static let recordingToggleHandledRequestIDKey = "recordingToggleHandledRequestID"
    private static let recordingIsActiveKey = "recordingIsActive"
    private static let recordingIsTranscribingKey = "recordingIsTranscribing"
    private static let recordingAudioLevelKey = "recordingAudioLevel"
    private static let recordingDecibelsKey = "recordingDecibels"
    private static let recordingDurationKey = "recordingDuration"
    private static let recordingStatusKey = "recordingStatus"
    private static let recordingUpdatedAtKey = "recordingUpdatedAt"
    private static let recognitionResultIDKey = "recognitionResultID"
    private static let recognitionResultTextKey = "recognitionResultText"
    private static let recognitionResultCreatedAtKey = "recognitionResultCreatedAt"
    private static let recognitionResultInsertedIDKey = "recognitionResultInsertedID"
    private static let keyboardAutoInsertRequestedAtKey = "keyboardAutoInsertRequestedAt"
    private static let keyboardAutoInsertPendingKey = "keyboardAutoInsertPending"
    private static let keyboardDiagnosticEventsKey = "keyboardDiagnosticEvents"
    private static let quickPhrasesKey = "quickPhrases"
    private static let keyboardQuickPhraseModuleVisibleKey =
        "keyboardQuickPhraseModuleVisible"
    private static let keyboardHapticsEnabledKey = "keyboardHapticsEnabled"
    private static let keyboardSelectedContentModuleKey =
        "keyboardSelectedContentModule"

    static func keyboardSelectedContentModuleRawValue() -> Int? {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              defaults.object(forKey: keyboardSelectedContentModuleKey) != nil else {
            return nil
        }

        return defaults.integer(forKey: keyboardSelectedContentModuleKey)
    }

    static func setKeyboardSelectedContentModuleRawValue(_ rawValue: Int) {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return
        }

        defaults.set(rawValue, forKey: keyboardSelectedContentModuleKey)
        defaults.synchronize()
    }

    static func keyboardQuickPhraseModuleVisible() -> Bool {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return true
        }
        guard defaults.object(forKey: keyboardQuickPhraseModuleVisibleKey) != nil else {
            return true
        }
        return defaults.bool(forKey: keyboardQuickPhraseModuleVisibleKey)
    }

    static func setKeyboardQuickPhraseModuleVisible(_ isVisible: Bool) {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return
        }
        defaults.set(isVisible, forKey: keyboardQuickPhraseModuleVisibleKey)
        defaults.synchronize()
    }

    static func keyboardHapticsEnabled() -> Bool {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return true
        }
        guard defaults.object(forKey: keyboardHapticsEnabledKey) != nil else {
            return true
        }
        return defaults.bool(forKey: keyboardHapticsEnabledKey)
    }

    static func setKeyboardHapticsEnabled(_ isEnabled: Bool) {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return
        }
        defaults.set(isEnabled, forKey: keyboardHapticsEnabledKey)
        defaults.synchronize()
    }

    static func quickPhrases() -> [SharedQuickPhrase] {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return defaultQuickPhrases
        }

        if let data = defaults.data(forKey: quickPhrasesKey),
           let decoded = try? JSONDecoder().decode([SharedQuickPhrase].self, from: data) {
            return sanitizedQuickPhrases(decoded)
        }

        saveQuickPhrases(defaultQuickPhrases)
        return defaultQuickPhrases
    }

    static func keyboardQuickPhrases() -> [SharedQuickPhrase] {
        Array(
            quickPhrases()
                .filter(\.isEnabled)
                .prefix(maximumKeyboardQuickPhraseCount)
        )
    }

    static func saveQuickPhrases(_ phrases: [SharedQuickPhrase]) {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let data = try? JSONEncoder().encode(sanitizedQuickPhrases(phrases)) else {
            return
        }

        defaults.set(data, forKey: quickPhrasesKey)
        defaults.synchronize()
    }

    private static func sanitizedQuickPhrases(
        _ phrases: [SharedQuickPhrase]
    ) -> [SharedQuickPhrase] {
        var ids = Set<UUID>()

        return phrases.compactMap { phrase in
            let title = phrase.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let content = phrase.content.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !title.isEmpty,
                  !content.isEmpty,
                  ids.insert(phrase.id).inserted else {
                return nil
            }

            return SharedQuickPhrase(
                id: phrase.id,
                title: String(title.prefix(64)),
                content: String(content.prefix(500)),
                isEnabled: phrase.isEnabled,
                createdAt: phrase.createdAt
            )
        }
    }

    static func recordKeyboardDiagnostic(
        _ event: String,
        detail: String = ""
    ) {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return
        }

        let timestamp = Date().timeIntervalSince1970
        let line = detail.isEmpty
            ? "\(timestamp) | \(event)"
            : "\(timestamp) | \(event) | \(detail)"
        var events = defaults.stringArray(forKey: keyboardDiagnosticEventsKey) ?? []
        events.append(line)
        if events.count > 40 {
            events.removeFirst(events.count - 40)
        }

        defaults.set(events, forKey: keyboardDiagnosticEventsKey)
        defaults.set(event, forKey: "keyboardLastDiagnosticEvent")
        defaults.set(detail, forKey: "keyboardLastDiagnosticDetail")
        defaults.set(timestamp, forKey: "keyboardLastDiagnosticAt")
        RecordingLaunchMetrics.mark(event, detail: detail)
    }

    @discardableResult
    static func requestRecordingToggle(
        shouldReturnToPreviousInterface: Bool = true
    ) -> SharedRecordingToggleRequest? {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return nil
        }

        let requestedAt = Date().timeIntervalSince1970
        let sourceHostBundleIdentifier = recentKeyboardHostBundleIdentifier(
            from: defaults,
            maxAge: 300
        )
        let request = SharedRecordingToggleRequest(
            id: UUID().uuidString,
            requestedAt: requestedAt,
            shouldReturnToPreviousInterface: shouldReturnToPreviousInterface,
            sourceHostBundleIdentifier: sourceHostBundleIdentifier
        )
        defaults.set(request.id, forKey: recordingToggleRequestIDKey)
        defaults.set(requestedAt, forKey: recordingToggleRequestedAtKey)
        defaults.set(shouldReturnToPreviousInterface, forKey: recordingToggleShouldReturnKey)
        defaults.set(
            sourceHostBundleIdentifier,
            forKey: recordingToggleHostBundleIdentifierKey
        )
        defaults.set(requestedAt, forKey: keyboardAutoInsertRequestedAtKey)
        defaults.set(true, forKey: keyboardAutoInsertPendingKey)
        // synchronize() only asks CFPreferences to flush pending changes. Its
        // Boolean result is not a reliable availability check for an App Group:
        // the values can already be visible to the containing app even when the
        // call reports false. The suite being unavailable is handled by the guard
        // above, so a completed write is a valid request.
        defaults.synchronize()
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(recordingToggleDarwinNotificationName as CFString),
            nil,
            nil,
            true
        )
        return request
    }

    static func latestRecordingToggleRequest() -> SharedRecordingToggleRequest? {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let id = defaults.string(forKey: recordingToggleRequestIDKey) else {
            return nil
        }

        return SharedRecordingToggleRequest(
            id: id,
            requestedAt: defaults.double(forKey: recordingToggleRequestedAtKey),
            shouldReturnToPreviousInterface: defaults.bool(
                forKey: recordingToggleShouldReturnKey
            ),
            sourceHostBundleIdentifier: defaults.string(
                forKey: recordingToggleHostBundleIdentifierKey
            )
        )
    }

    static func latestKeyboardHostBundleIdentifier() -> String? {
        UserDefaults(suiteName: appGroupIdentifier)?
            .string(forKey: keyboardHostBundleIdentifierKey)
    }

    static func latestRecentKeyboardHostBundleIdentifier(
        maxAge: TimeInterval = 300
    ) -> String? {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return nil
        }
        return recentKeyboardHostBundleIdentifier(from: defaults, maxAge: maxAge)
    }

    static func latestKeyboardHostBundleIdentifierCapturedAt() -> TimeInterval {
        UserDefaults(suiteName: appGroupIdentifier)?
            .double(forKey: keyboardHostBundleIdentifierCapturedAtKey) ?? 0
    }

    private static func recentKeyboardHostBundleIdentifier(
        from defaults: UserDefaults,
        maxAge: TimeInterval
    ) -> String? {
        let capturedAt = defaults.double(
            forKey: keyboardHostBundleIdentifierCapturedAtKey
        )
        let age = Date().timeIntervalSince1970 - capturedAt
        guard age >= -1, age < maxAge else {
            return nil
        }
        return defaults.string(forKey: keyboardHostBundleIdentifierKey)
    }

    static func storeKeyboardHostBundleIdentifier(_ bundleIdentifier: String) {
        guard !bundleIdentifier.isEmpty,
              let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return
        }

        defaults.set(bundleIdentifier, forKey: keyboardHostBundleIdentifierKey)
        defaults.set(
            Date().timeIntervalSince1970,
            forKey: keyboardHostBundleIdentifierCapturedAtKey
        )
        defaults.set(
            "legacy host captured",
            forKey: "keyboardHostTrackerRefreshStatus"
        )
        defaults.synchronize()
    }

    static func storeKeyboardHostCaptureFailure(_ status: String) {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return
        }

        defaults.set(status, forKey: "keyboardHostTrackerRefreshStatus")
    }

    static func latestHandledRecordingToggleRequestID() -> String? {
        UserDefaults(suiteName: appGroupIdentifier)?
            .string(forKey: recordingToggleHandledRequestIDKey)
    }

    static func markRecordingToggleRequestHandled(_ id: String) {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return
        }

        defaults.set(id, forKey: recordingToggleHandledRequestIDKey)
        defaults.synchronize()
    }

    static func latestKeyboardAutoInsertRequestedAt() -> TimeInterval {
        UserDefaults(suiteName: appGroupIdentifier)?
            .double(forKey: keyboardAutoInsertRequestedAtKey) ?? 0
    }

    static func isKeyboardAutoInsertPending() -> Bool {
        UserDefaults(suiteName: appGroupIdentifier)?
            .bool(forKey: keyboardAutoInsertPendingKey) ?? false
    }

    static func cancelKeyboardAutoInsert() {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return
        }

        defaults.set(false, forKey: keyboardAutoInsertPendingKey)
        defaults.synchronize()
    }

    static func updateRecordingSnapshot(
        isRecording: Bool,
        isTranscribing: Bool,
        audioLevel: Double,
        decibels: Double,
        duration: Double,
        status: String
    ) {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return
        }

        defaults.set(isRecording, forKey: recordingIsActiveKey)
        defaults.set(isTranscribing, forKey: recordingIsTranscribingKey)
        defaults.set(max(0, min(1, audioLevel)), forKey: recordingAudioLevelKey)
        defaults.set(decibels, forKey: recordingDecibelsKey)
        defaults.set(duration, forKey: recordingDurationKey)
        defaults.set(status, forKey: recordingStatusKey)
        defaults.set(Date().timeIntervalSince1970, forKey: recordingUpdatedAtKey)
        defaults.synchronize()
    }

    static func latestRecordingSnapshot() -> SharedRecordingSnapshot {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return SharedRecordingSnapshot(
                isRecording: false,
                isTranscribing: false,
                audioLevel: 0,
                decibels: -80,
                duration: 0,
                status: "等待完整访问权限",
                updatedAt: 0
            )
        }

        return SharedRecordingSnapshot(
            isRecording: defaults.bool(forKey: recordingIsActiveKey),
            isTranscribing: defaults.bool(forKey: recordingIsTranscribingKey),
            audioLevel: defaults.double(forKey: recordingAudioLevelKey),
            decibels: defaults.object(forKey: recordingDecibelsKey) as? Double ?? -80,
            duration: defaults.double(forKey: recordingDurationKey),
            status: defaults.string(forKey: recordingStatusKey) ?? "准备录音",
            updatedAt: defaults.double(forKey: recordingUpdatedAtKey)
        )
    }

    static func clearRecognitionResult() {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return
        }

        defaults.removeObject(forKey: recognitionResultIDKey)
        defaults.removeObject(forKey: recognitionResultTextKey)
        defaults.removeObject(forKey: recognitionResultCreatedAtKey)
        defaults.synchronize()
    }

    @discardableResult
    static func publishRecognitionResult(_ text: String) -> String? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedText.isEmpty,
              let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return nil
        }

        let id = UUID().uuidString
        defaults.set(id, forKey: recognitionResultIDKey)
        defaults.set(trimmedText, forKey: recognitionResultTextKey)
        defaults.set(Date().timeIntervalSince1970, forKey: recognitionResultCreatedAtKey)
        defaults.synchronize()
        return id
    }

    static func latestRecognitionResult() -> SharedRecognitionResult? {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let id = defaults.string(forKey: recognitionResultIDKey),
              let text = defaults.string(forKey: recognitionResultTextKey),
              !text.isEmpty else {
            return nil
        }

        return SharedRecognitionResult(
            id: id,
            text: text,
            createdAt: defaults.double(forKey: recognitionResultCreatedAtKey)
        )
    }

    static func latestInsertedRecognitionResultID() -> String? {
        UserDefaults(suiteName: appGroupIdentifier)?
            .string(forKey: recognitionResultInsertedIDKey)
    }

    static func markRecognitionResultInserted(_ id: String) {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return
        }

        defaults.set(id, forKey: recognitionResultInsertedIDKey)
        defaults.set(false, forKey: keyboardAutoInsertPendingKey)
        defaults.synchronize()
    }
}
