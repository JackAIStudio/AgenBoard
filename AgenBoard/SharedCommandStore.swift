import Foundation
import os

struct SharedRecordingSnapshot {
    let isRecording: Bool
    let isTranscribing: Bool
    let isBackgroundStartReady: Bool
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

enum SharedRecordingCommand: String {
    case start
    case stop
}

enum SharedKeyboardHostKind: String {
    case application
    case systemInterface
}

struct SharedKeyboardHostCapture {
    let bundleIdentifier: String
    let capturedAt: TimeInterval
    let generation: String
    let kind: SharedKeyboardHostKind

    var canOpenApplication: Bool {
        kind == .application
    }
}

struct SharedRecordingToggleRequest {
    let id: String
    let requestedAt: TimeInterval
    let requiresForegroundRoundTrip: Bool
    let command: SharedRecordingCommand
    let sourceHost: SharedKeyboardHostCapture?
}

enum SharedRecordingRequestPhase: String {
    case accepted
    case recording
    case stopped
    case failed
}

struct SharedRecordingRequestResponse {
    let requestID: String
    let command: SharedRecordingCommand
    let phase: SharedRecordingRequestPhase
    let message: String
    let updatedAt: TimeInterval
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
    static let appBundleIdentifier = configuredIdentifier(
        forInfoDictionaryKey: "AgenBoardAppBundleIdentifier",
        fallback: "dev.local.agenboard"
    )
    static let appGroupIdentifier = configuredIdentifier(
        forInfoDictionaryKey: "AgenBoardAppGroupIdentifier",
        fallback: "group.dev.local.agenboard"
    )
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
    private static let recordingToggleRequiresForegroundRoundTripKey =
        "recordingToggleRequiresForegroundRoundTrip"
    private static let recordingCommandKey = "recordingCommand"
    private static let recordingHostBundleIdentifierKey =
        "recordingHostBundleIdentifier"
    private static let recordingHostCapturedAtKey = "recordingHostCapturedAt"
    private static let recordingHostGenerationKey = "recordingHostGeneration"
    private static let keyboardHostBundleIdentifierKey =
        "keyboardHostBundleIdentifier"
    private static let keyboardHostCapturedAtKey =
        "keyboardHostBundleIdentifierCapturedAt"
    private static let keyboardHostGenerationKey = "keyboardHostCaptureGeneration"
    private static let keyboardHostConsumedGenerationKey =
        "keyboardHostLastConsumedCaptureGeneration"
    private static let recordingToggleHandledRequestIDKey = "recordingToggleHandledRequestID"
    private static let recordingResponseRequestIDKey = "recordingResponseRequestID"
    private static let recordingResponseCommandKey = "recordingResponseCommand"
    private static let recordingResponsePhaseKey = "recordingResponsePhase"
    private static let recordingResponseMessageKey = "recordingResponseMessage"
    private static let recordingResponseUpdatedAtKey = "recordingResponseUpdatedAt"
    private static let recordingIsActiveKey = "recordingIsActive"
    private static let recordingIsTranscribingKey = "recordingIsTranscribing"
    private static let recordingBackgroundStartReadyKey =
        "recordingBackgroundStartReady"
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

    private static func configuredIdentifier(
        forInfoDictionaryKey key: String,
        fallback: String
    ) -> String {
        guard let value = Bundle.main.object(
            forInfoDictionaryKey: key
        ) as? String else {
            return fallback
        }

        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !normalized.contains("$(") else {
            return fallback
        }
        return normalized
    }

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
            return false
        }
        guard defaults.object(forKey: keyboardQuickPhraseModuleVisibleKey) != nil else {
            return false
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

    static func keyboardHostDiagnosticSummary() -> String {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return "Hook 诊断：App Group 不可用"
        }

        let installStatus = defaults.string(
            forKey: "keyboardHostTrackerInstallStatus"
        ) ?? "未安装"
        let enabledStatus = defaults.string(
            forKey: "keyboardHostTrackerEnabledOverride"
        ) ?? "未启用"
        let refreshStatus = defaults.string(
            forKey: "keyboardHostTrackerRefreshStatus"
        ) ?? "未刷新"
        let lastValueClass = defaults.string(
            forKey: "keyboardHostTrackerLastValueClass"
        ) ?? "无回调"
        let lastBundleIdentifier = defaults.string(
            forKey: keyboardHostBundleIdentifierKey
        )
        let lastCapturedAt = defaults.double(forKey: keyboardHostCapturedAtKey)
        let captureStatus: String
        if let lastBundleIdentifier, lastCapturedAt > 0 {
            let age = max(0, Date().timeIntervalSince1970 - lastCapturedAt)
            let requestedAt = defaults.double(
                forKey: recordingToggleRequestedAtKey
            )
            let requestTiming: String
            if requestedAt > 0 {
                let offset = lastCapturedAt - requestedAt
                requestTiming = offset >= 0
                    ? String(format: "，请求后 %.1f 秒", offset)
                    : String(format: "，请求前 %.1f 秒", abs(offset))
            } else {
                requestTiming = ""
            }
            captureStatus = String(
                format: "最近捕获：%@（%.1f 秒前%@）",
                lastBundleIdentifier,
                age,
                requestTiming
            )
        } else {
            captureStatus = "最近捕获：无"
        }
        return "\(captureStatus)；Hook：\(installStatus)；Arbiter：\(enabledStatus)；刷新：\(refreshStatus)；回调值：\(lastValueClass)"
    }

    @discardableResult
    static func requestRecordingCommand(
        _ command: SharedRecordingCommand,
        requiresForegroundRoundTrip: Bool = true,
        sourceHost: SharedKeyboardHostCapture? = nil
    ) -> SharedRecordingToggleRequest? {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return nil
        }

        let requestedAt = Date().timeIntervalSince1970
        let request = SharedRecordingToggleRequest(
            id: UUID().uuidString,
            requestedAt: requestedAt,
            requiresForegroundRoundTrip: requiresForegroundRoundTrip,
            command: command,
            sourceHost: sourceHost
        )
        defaults.set(request.id, forKey: recordingToggleRequestIDKey)
        defaults.set(requestedAt, forKey: recordingToggleRequestedAtKey)
        defaults.set(
            requiresForegroundRoundTrip,
            forKey: recordingToggleRequiresForegroundRoundTripKey
        )
        defaults.set(command.rawValue, forKey: recordingCommandKey)
        if let sourceHost {
            defaults.set(
                sourceHost.bundleIdentifier,
                forKey: recordingHostBundleIdentifierKey
            )
            defaults.set(sourceHost.capturedAt, forKey: recordingHostCapturedAtKey)
            defaults.set(sourceHost.generation, forKey: recordingHostGenerationKey)
        } else {
            defaults.removeObject(forKey: recordingHostBundleIdentifierKey)
            defaults.removeObject(forKey: recordingHostCapturedAtKey)
            defaults.removeObject(forKey: recordingHostGenerationKey)
        }
        defaults.removeObject(forKey: recordingResponseRequestIDKey)
        defaults.removeObject(forKey: recordingResponseCommandKey)
        defaults.removeObject(forKey: recordingResponsePhaseKey)
        defaults.removeObject(forKey: recordingResponseMessageKey)
        defaults.removeObject(forKey: recordingResponseUpdatedAtKey)
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

        defaults.synchronize()
        let requestedAt = defaults.double(forKey: recordingToggleRequestedAtKey)
        let requiresForegroundRoundTrip = defaults.bool(
            forKey: recordingToggleRequiresForegroundRoundTripKey
        )
        var sourceHost = keyboardHostCapture(
            bundleIdentifier: defaults.string(forKey: recordingHostBundleIdentifierKey),
            capturedAt: defaults.double(forKey: recordingHostCapturedAtKey),
            generation: defaults.string(forKey: recordingHostGenerationKey)
        )
        if sourceHost == nil,
           let lateCapture = keyboardHostCaptureAssociatedWithRequest(
               from: defaults,
               requestedAt: requestedAt
           ) {
            // The arbiter sometimes reports the source only after the containing
            // app has started opening. Attach that callback to the still-current
            // request so the main app can enable its return button dynamically.
            defaults.set(
                lateCapture.bundleIdentifier,
                forKey: recordingHostBundleIdentifierKey
            )
            defaults.set(lateCapture.capturedAt, forKey: recordingHostCapturedAtKey)
            defaults.set(lateCapture.generation, forKey: recordingHostGenerationKey)
            defaults.synchronize()
            sourceHost = lateCapture
        }

        return SharedRecordingToggleRequest(
            id: id,
            requestedAt: requestedAt,
            requiresForegroundRoundTrip: requiresForegroundRoundTrip,
            command: SharedRecordingCommand(
                rawValue: defaults.string(forKey: recordingCommandKey) ?? ""
            ) ?? .start,
            sourceHost: sourceHost
        )
    }

    private static func keyboardHostCaptureAssociatedWithRequest(
        from defaults: UserDefaults,
        requestedAt: TimeInterval
    ) -> SharedKeyboardHostCapture? {
        let capturedAt = defaults.double(forKey: keyboardHostCapturedAtKey)
        let now = Date().timeIntervalSince1970
        guard requestedAt > 0,
              capturedAt >= requestedAt - 2,
              capturedAt <= requestedAt + 3,
              capturedAt <= now + 1 else {
            return nil
        }

        return keyboardHostCapture(
            bundleIdentifier: defaults.string(forKey: keyboardHostBundleIdentifierKey),
            capturedAt: capturedAt,
            generation: defaults.string(forKey: keyboardHostGenerationKey)
        )
    }

    static func latestUnconsumedKeyboardHostCapture(
        presentationStartedAt: TimeInterval,
        earlyCallbackTolerance: TimeInterval = 4
    ) -> SharedKeyboardHostCapture? {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return nil
        }

        // The ObjC hook can run from +load before Swift's view lifecycle. Read
        // that callback instead of clearing it and waiting for another one.
        defaults.synchronize()
        let capturedAt = defaults.double(forKey: keyboardHostCapturedAtKey)
        let now = Date().timeIntervalSince1970
        guard capturedAt >= presentationStartedAt - earlyCallbackTolerance,
              capturedAt <= now + 1,
              let generation = defaults.string(forKey: keyboardHostGenerationKey),
              generation != defaults.string(forKey: keyboardHostConsumedGenerationKey) else {
            return nil
        }

        return keyboardHostCapture(
            bundleIdentifier: defaults.string(forKey: keyboardHostBundleIdentifierKey),
            capturedAt: capturedAt,
            generation: generation
        )
    }

    static func markKeyboardHostCaptureConsumed(_ capture: SharedKeyboardHostCapture) {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return
        }

        defaults.set(capture.generation, forKey: keyboardHostConsumedGenerationKey)
        defaults.synchronize()
    }

    static func hostKind(for bundleIdentifier: String) -> SharedKeyboardHostKind {
        isReturnableHostBundleIdentifier(bundleIdentifier)
            ? .application
            : .systemInterface
    }

    static func isReturnableHostBundleIdentifier(_ bundleIdentifier: String) -> Bool {
        let normalized = bundleIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized.contains("."),
              normalized != appBundleIdentifier.lowercased(),
              normalized != Bundle.main.bundleIdentifier?.lowercased() else {
            return false
        }

        let blockedIdentifiers: Set<String> = [
            "com.apple.springboard",
            "com.apple.spotlight",
            "com.apple.searchui",
            "com.apple.inputui",
            "com.apple.keyboardservices"
        ]
        guard !blockedIdentifiers.contains(normalized) else {
            return false
        }

        let blockedFragments = [
            "springboard",
            "spotlight",
            "searchui",
            "inputui",
            "keyboardservices",
            "textinput"
        ]
        return !blockedFragments.contains(where: normalized.contains)
    }

    private static func keyboardHostCapture(
        bundleIdentifier: String?,
        capturedAt: TimeInterval,
        generation: String?
    ) -> SharedKeyboardHostCapture? {
        guard let bundleIdentifier,
              !bundleIdentifier.isEmpty,
              capturedAt > 0,
              let generation,
              !generation.isEmpty else {
            return nil
        }

        return SharedKeyboardHostCapture(
            bundleIdentifier: bundleIdentifier,
            capturedAt: capturedAt,
            generation: generation,
            kind: hostKind(for: bundleIdentifier)
        )
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

    static func updateRecordingRequestResponse(
        for request: SharedRecordingToggleRequest,
        phase: SharedRecordingRequestPhase,
        message: String = ""
    ) {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return
        }

        defaults.set(request.id, forKey: recordingResponseRequestIDKey)
        defaults.set(request.command.rawValue, forKey: recordingResponseCommandKey)
        defaults.set(phase.rawValue, forKey: recordingResponsePhaseKey)
        defaults.set(message, forKey: recordingResponseMessageKey)
        defaults.set(Date().timeIntervalSince1970, forKey: recordingResponseUpdatedAtKey)
        defaults.synchronize()
    }

    static func latestRecordingRequestResponse() -> SharedRecordingRequestResponse? {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let requestID = defaults.string(forKey: recordingResponseRequestIDKey),
              let commandRawValue = defaults.string(forKey: recordingResponseCommandKey),
              let command = SharedRecordingCommand(rawValue: commandRawValue),
              let phaseRawValue = defaults.string(forKey: recordingResponsePhaseKey),
              let phase = SharedRecordingRequestPhase(rawValue: phaseRawValue) else {
            return nil
        }

        return SharedRecordingRequestResponse(
            requestID: requestID,
            command: command,
            phase: phase,
            message: defaults.string(forKey: recordingResponseMessageKey) ?? "",
            updatedAt: defaults.double(forKey: recordingResponseUpdatedAtKey)
        )
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

    static func setBackgroundRecordingStartReady(_ isReady: Bool) {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return
        }

        defaults.set(isReady, forKey: recordingBackgroundStartReadyKey)
        defaults.synchronize()
    }

    static func latestRecordingSnapshot() -> SharedRecordingSnapshot {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return SharedRecordingSnapshot(
                isRecording: false,
                isTranscribing: false,
                isBackgroundStartReady: false,
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
            isBackgroundStartReady: defaults.bool(
                forKey: recordingBackgroundStartReadyKey
            ),
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
