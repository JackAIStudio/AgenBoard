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
    let statusChangedAt: TimeInterval
    let updatedAt: TimeInterval
}

struct SharedRecognitionResult {
    let id: String
    let text: String
    let createdAt: TimeInterval
    let autoInsertRequestedAt: TimeInterval
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

struct SharedKeyboardAccessVerification {
    let requestID: String
    let requestedAt: TimeInterval
    let verifiedAt: TimeInterval?

    var isVerified: Bool {
        verifiedAt != nil
    }
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
            title: "你好",
            content: "你好，很高兴认识你！",
            createdAt: Date(timeIntervalSince1970: 0)
        ),
        SharedQuickPhrase(
            title: "稍后回复",
            content: "我现在不方便，稍后回复你。",
            createdAt: Date(timeIntervalSince1970: 1)
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
    private static let recordingStatusChangedAtKey = "recordingStatusChangedAt"
    private static let recordingUpdatedAtKey = "recordingUpdatedAt"
    private static let recognitionResultIDKey = "recognitionResultID"
    private static let recognitionResultTextKey = "recognitionResultText"
    private static let recognitionResultCreatedAtKey = "recognitionResultCreatedAt"
    private static let recognitionResultAutoInsertRequestedAtKey =
        "recognitionResultAutoInsertRequestedAt"
    private static let recognitionResultInsertedIDKey = "recognitionResultInsertedID"
    private static let recognitionResultInsertionAttemptedAtKey =
        "recognitionResultInsertionAttemptedAt"
    private static let keyboardAutoInsertRequestedAtKey = "keyboardAutoInsertRequestedAt"
    private static let keyboardAutoInsertPendingKey = "keyboardAutoInsertPending"
    private static let keyboardDiagnosticEventsKey = "keyboardDiagnosticEvents"
    private static let quickPhrasesKey = "quickPhrases"
    private static let keyboardQuickPhraseModuleVisibleKey =
        "keyboardQuickPhraseModuleVisible"
    private static let keyboardHapticsEnabledKey = "keyboardHapticsEnabled"
    private static let keyboardSelectedContentModuleKey =
        "keyboardSelectedContentModule"
    private static let keyboardAccessVerificationRequestIDKey =
        "keyboardAccessVerificationRequestIDV1"
    private static let keyboardAccessVerificationRequestedAtKey =
        "keyboardAccessVerificationRequestedAtV1"
    private static let keyboardAccessVerificationResponseIDKey =
        "keyboardAccessVerificationResponseIDV1"
    private static let keyboardAccessVerificationVerifiedAtKey =
        "keyboardAccessVerificationVerifiedAtV1"

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

    @discardableResult
    static func requestKeyboardAccessVerification() -> SharedKeyboardAccessVerification? {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return nil
        }

        let requestID = UUID().uuidString
        let requestedAt = Date().timeIntervalSince1970
        defaults.set(requestID, forKey: keyboardAccessVerificationRequestIDKey)
        defaults.set(requestedAt, forKey: keyboardAccessVerificationRequestedAtKey)
        defaults.synchronize()
        return SharedKeyboardAccessVerification(
            requestID: requestID,
            requestedAt: requestedAt,
            verifiedAt: nil
        )
    }

    static func respondToKeyboardAccessVerification(hasFullAccess: Bool) {
        guard hasFullAccess,
              let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let requestID = defaults.string(
                forKey: keyboardAccessVerificationRequestIDKey
              ) else {
            return
        }

        defaults.set(requestID, forKey: keyboardAccessVerificationResponseIDKey)
        defaults.set(
            Date().timeIntervalSince1970,
            forKey: keyboardAccessVerificationVerifiedAtKey
        )
        defaults.synchronize()
    }

    static func latestKeyboardAccessVerification() -> SharedKeyboardAccessVerification? {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let requestID = defaults.string(
                forKey: keyboardAccessVerificationRequestIDKey
              ) else {
            return nil
        }

        let responseID = defaults.string(forKey: keyboardAccessVerificationResponseIDKey)
        let verifiedTimestamp = defaults.double(
            forKey: keyboardAccessVerificationVerifiedAtKey
        )
        let verifiedAt = responseID == requestID && verifiedTimestamp > 0
            ? verifiedTimestamp
            : nil

        return SharedKeyboardAccessVerification(
            requestID: requestID,
            requestedAt: defaults.double(
                forKey: keyboardAccessVerificationRequestedAtKey
            ),
            verifiedAt: verifiedAt
        )
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
        defaults.synchronize()
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

        let updatedAt = Date().timeIntervalSince1970
        if defaults.string(forKey: recordingStatusKey) != status {
            defaults.set(updatedAt, forKey: recordingStatusChangedAtKey)
        }
        defaults.set(isRecording, forKey: recordingIsActiveKey)
        defaults.set(isTranscribing, forKey: recordingIsTranscribingKey)
        defaults.set(max(0, min(1, audioLevel)), forKey: recordingAudioLevelKey)
        defaults.set(decibels, forKey: recordingDecibelsKey)
        defaults.set(duration, forKey: recordingDurationKey)
        defaults.set(status, forKey: recordingStatusKey)
        defaults.set(updatedAt, forKey: recordingUpdatedAtKey)
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
                statusChangedAt: 0,
                updatedAt: 0
            )
        }

        let updatedAt = defaults.double(forKey: recordingUpdatedAtKey)
        let storedStatusChangedAt = defaults.double(forKey: recordingStatusChangedAtKey)
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
            statusChangedAt: storedStatusChangedAt > 0 ? storedStatusChangedAt : updatedAt,
            updatedAt: updatedAt
        )
    }

    static func clearRecognitionResult() {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return
        }

        defaults.removeObject(forKey: recognitionResultIDKey)
        defaults.removeObject(forKey: recognitionResultTextKey)
        defaults.removeObject(forKey: recognitionResultCreatedAtKey)
        defaults.removeObject(forKey: recognitionResultAutoInsertRequestedAtKey)
        defaults.removeObject(forKey: recognitionResultInsertionAttemptedAtKey)
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
        let autoInsertRequestedAt = defaults.bool(forKey: keyboardAutoInsertPendingKey)
            ? defaults.double(forKey: keyboardAutoInsertRequestedAtKey)
            : 0
        defaults.set(id, forKey: recognitionResultIDKey)
        defaults.set(trimmedText, forKey: recognitionResultTextKey)
        defaults.set(Date().timeIntervalSince1970, forKey: recognitionResultCreatedAtKey)
        if autoInsertRequestedAt > 0 {
            defaults.set(
                autoInsertRequestedAt,
                forKey: recognitionResultAutoInsertRequestedAtKey
            )
        } else {
            defaults.removeObject(forKey: recognitionResultAutoInsertRequestedAtKey)
        }
        defaults.removeObject(forKey: recognitionResultInsertionAttemptedAtKey)
        defaults.synchronize()
        recordKeyboardDiagnostic(
            "recognition_result_published",
            detail: "id=\(id) chars=\(trimmedText.count) auto_insert=\(autoInsertRequestedAt > 0 ? 1 : 0)"
        )
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
            createdAt: defaults.double(forKey: recognitionResultCreatedAtKey),
            autoInsertRequestedAt: defaults.double(
                forKey: recognitionResultAutoInsertRequestedAtKey
            )
        )
    }

    static func latestInsertedRecognitionResultID() -> String? {
        UserDefaults(suiteName: appGroupIdentifier)?
            .string(forKey: recognitionResultInsertedIDKey)
    }

    static func latestRecognitionResultInsertionAttemptedAt() -> TimeInterval {
        UserDefaults(suiteName: appGroupIdentifier)?
            .double(forKey: recognitionResultInsertionAttemptedAtKey) ?? 0
    }

    static func markRecognitionResultInsertionAttempted(_ id: String) {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              defaults.string(forKey: recognitionResultIDKey) == id else {
            return
        }

        let attemptedAt = Date().timeIntervalSince1970
        defaults.set(id, forKey: recognitionResultInsertedIDKey)
        defaults.set(attemptedAt, forKey: recognitionResultInsertionAttemptedAtKey)
        defaults.set(false, forKey: keyboardAutoInsertPendingKey)
        defaults.synchronize()
        recordKeyboardDiagnostic(
            "recognition_insertion_attempt_recorded",
            detail: "id=\(id)"
        )
    }
}

enum SharedPinyinImportMode: String, Codable, Sendable {
    case merge
    case replace
}

struct SharedPinyinUserDataSnapshot: Sendable {
    let url: URL
    let entryCount: Int
}

struct SharedPendingPinyinImport: Codable, Sendable {
    let id: UUID
    let mode: SharedPinyinImportMode
    let entryCount: Int
    let createdAt: Date
}

/// Owns the portable side of Rime's learned user dictionary. Rime keeps the
/// live database as LevelDB, while its native sync task produces a readable,
/// mergeable `*.userdb.txt` snapshot. Only that portable snapshot crosses the
/// app's export/import boundary.
enum SharedPinyinUserDataStore {
    static let dictionaryName = "rime_ice"
    static let snapshotFileName = "\(dictionaryName).userdb.txt"

    private static let pendingDirectoryName = "PendingRimeUserDataImport"
    private static let pendingMetadataFileName = "pending.json"
    private static let maximumSnapshotBytes = 64 * 1_024 * 1_024
    private static let maximumEntryCount = 500_000
    private static let maximumLineLength = 16_384
    private static let snapshotRefreshRequiredKey =
        "pinyinPortableSnapshotRefreshRequiredV1"

    static func userDataDirectoryURL(
        fileManager: FileManager = .default
    ) throws -> URL {
        try appGroupContainerURL(fileManager: fileManager).appendingPathComponent(
            "RimeUserData",
            isDirectory: true
        )
    }

    /// The keyboard remains usable before Full Access is granted by keeping a
    /// private user dictionary. Once the App Group becomes available,
    /// `migrateLegacyPrivateUserDataIfNeeded` copies that dictionary into the
    /// exportable shared location.
    static func runtimeUserDataDirectoryURL(
        fileManager: FileManager = .default
    ) -> URL {
        if let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: SharedCommandStore.appGroupIdentifier
        ) {
            return containerURL.appendingPathComponent(
                "RimeUserData",
                isDirectory: true
            )
        }
        return privateUserDataDirectoryURL(fileManager: fileManager)
    }

    /// Copies user data written by older builds that silently fell back to the
    /// extension's private Application Support directory. Keeping the source
    /// copy makes this migration recoverable if the destination later proves
    /// unusable.
    static func migrateLegacyPrivateUserDataIfNeeded(
        fileManager: FileManager = .default
    ) throws {
        let sharedURL = try userDataDirectoryURL(fileManager: fileManager)
        guard !fileManager.fileExists(atPath: sharedURL.path) else {
            return
        }
        let legacyURL = privateUserDataDirectoryURL(fileManager: fileManager)
        guard legacyURL.standardizedFileURL != sharedURL.standardizedFileURL,
              fileManager.fileExists(atPath: legacyURL.path) else {
            return
        }
        try fileManager.copyItem(at: legacyURL, to: sharedURL)
    }

    /// Pins librime's otherwise-relative `sync/` directory inside the shared
    /// App Group so the keyboard extension and containing app see the same
    /// portable snapshots.
    static func ensureRimeSyncConfiguration(
        at userDataURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let syncDirectory = userDataURL.appendingPathComponent(
            "sync",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: syncDirectory,
            withIntermediateDirectories: true
        )

        let installationURL = userDataURL.appendingPathComponent("installation.yaml")
        var lines: [String] = []
        if fileManager.fileExists(atPath: installationURL.path) {
            lines = try String(contentsOf: installationURL, encoding: .utf8)
                .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                .map(String.init)
        }

        let escapedSyncPath = syncDirectory.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let syncLine = "sync_dir: \"\(escapedSyncPath)\""
        if let index = lines.firstIndex(where: { $0.hasPrefix("sync_dir:") }) {
            lines[index] = syncLine
        } else {
            lines.append(syncLine)
        }
        if !lines.contains(where: { $0.hasPrefix("installation_id:") }) {
            lines.append("installation_id: \"\(UUID().uuidString)\"")
        }

        let contents = lines
            .filter { !$0.isEmpty }
            .joined(separator: "\n") + "\n"
        try Data(contents.utf8).write(to: installationURL, options: .atomic)
    }

    static func latestSnapshot(
        fileManager: FileManager = .default
    ) throws -> SharedPinyinUserDataSnapshot? {
        if try pendingImport(fileManager: fileManager) != nil {
            throw SharedPinyinUserDataError.pendingImportNotApplied
        }
        let hasLiveDatabase = try hasLiveUserDatabase(fileManager: fileManager)
        guard let snapshot = try currentInstallationSnapshot(
            fileManager: fileManager
        ) else {
            if hasLiveDatabase {
                throw SharedPinyinUserDataError.snapshotNotReady
            }
            return nil
        }
        if hasLiveDatabase && isPortableSnapshotRefreshRequired() {
            throw SharedPinyinUserDataError.snapshotNotReady
        }
        return snapshot
    }

    /// Marks the readable artifact stale before a newly learned candidate can
    /// be lost with the extension process. Export will refuse an older snapshot
    /// until native sync has produced and validated its replacement.
    static func markPortableSnapshotNeedsRefresh() {
        guard let defaults = UserDefaults(
            suiteName: SharedCommandStore.appGroupIdentifier
        ) else {
            return
        }
        defaults.set(true, forKey: snapshotRefreshRequiredKey)
        defaults.synchronize()
    }

    static func markPortableSnapshotCurrent() {
        guard let defaults = UserDefaults(
            suiteName: SharedCommandStore.appGroupIdentifier
        ) else {
            return
        }
        defaults.set(false, forKey: snapshotRefreshRequiredKey)
        defaults.synchronize()
    }

    /// A pre-existing LevelDB can come from an older build which learned
    /// candidates before portable snapshots were supported. The keyboard uses
    /// this check once during preparation so merely opening the keyboard is
    /// enough to bootstrap that database into an exportable snapshot.
    static func requiresPortableSnapshot(
        fileManager: FileManager = .default
    ) -> Bool {
        guard (try? hasLiveUserDatabase(fileManager: fileManager)) == true else {
            return false
        }
        if isPortableSnapshotRefreshRequired() {
            return true
        }
        do {
            return try currentInstallationSnapshot(fileManager: fileManager) == nil
        } catch {
            return true
        }
    }

    /// Confirms that a successful native task actually produced the artifact
    /// consumed by export instead of trusting the task's Boolean alone.
    static func hasCompletePortableSnapshotIfNeeded(
        fileManager: FileManager = .default
    ) -> Bool {
        guard (try? hasLiveUserDatabase(fileManager: fileManager)) == true else {
            return true
        }
        do {
            return try currentInstallationSnapshot(fileManager: fileManager) != nil
        } catch {
            return false
        }
    }

    @discardableResult
    static func validateSnapshot(at url: URL) throws -> Int {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumSnapshotBytes else {
            throw SharedPinyinUserDataError.snapshotTooLarge
        }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw SharedPinyinUserDataError.invalidUTF8
        }

        var hasDictionaryHeader = false
        var hasDatabaseTypeHeader = false
        var hasUserHeader = false
        var entryCount = 0

        for rawLine in text.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        ) {
            guard rawLine.count <= maximumLineLength else {
                throw SharedPinyinUserDataError.invalidLine
            }
            let line = String(rawLine)
            if line.isEmpty || line.hasPrefix("# Rime user dictionary") {
                continue
            }
            if line.hasPrefix("#@/") {
                let fields = line.split(
                    maxSplits: 1,
                    omittingEmptySubsequences: true,
                    whereSeparator: { $0 == "\t" || $0 == " " }
                )
                guard fields.count == 2 else {
                    throw SharedPinyinUserDataError.invalidHeader
                }
                switch fields[0] {
                case "#@/db_name":
                    guard fields[1] == Substring(dictionaryName) else {
                        throw SharedPinyinUserDataError.wrongDictionary
                    }
                    hasDictionaryHeader = true
                case "#@/db_type":
                    guard fields[1] == "userdb" else {
                        throw SharedPinyinUserDataError.invalidHeader
                    }
                    hasDatabaseTypeHeader = true
                case "#@/user_id":
                    guard !fields[1].isEmpty else {
                        throw SharedPinyinUserDataError.invalidHeader
                    }
                    hasUserHeader = true
                default:
                    break
                }
                continue
            }
            if line.hasPrefix("#") {
                continue
            }

            let fields = line.split(
                separator: "\t",
                omittingEmptySubsequences: false
            )
            guard fields.count >= 3,
                  !fields[0].isEmpty,
                  !fields[1].isEmpty else {
                throw SharedPinyinUserDataError.invalidLine
            }
            let metadata = String(fields[2])
            guard metadata.contains("c="),
                  metadata.contains("d="),
                  metadata.contains("t=") else {
                throw SharedPinyinUserDataError.invalidLine
            }
            entryCount += 1
            guard entryCount <= maximumEntryCount else {
                throw SharedPinyinUserDataError.tooManyEntries
            }
        }

        guard hasDictionaryHeader, hasDatabaseTypeHeader, hasUserHeader else {
            throw SharedPinyinUserDataError.invalidHeader
        }
        return entryCount
    }

    @discardableResult
    static func stageImport(
        from sourceURL: URL,
        mode: SharedPinyinImportMode,
        fileManager: FileManager = .default
    ) throws -> SharedPendingPinyinImport {
        let entryCount = try validateSnapshot(at: sourceURL)
        let pending = SharedPendingPinyinImport(
            id: UUID(),
            mode: mode,
            entryCount: entryCount,
            createdAt: Date()
        )
        let containerURL = try appGroupContainerURL(fileManager: fileManager)
        let destinationDirectory = containerURL.appendingPathComponent(
            pendingDirectoryName,
            isDirectory: true
        )
        let stagingDirectory = containerURL.appendingPathComponent(
            ".\(pendingDirectoryName)-\(pending.id.uuidString)",
            isDirectory: true
        )

        do {
            try fileManager.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(
                at: sourceURL,
                to: stagingDirectory.appendingPathComponent(snapshotFileName)
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(pending).write(
                to: stagingDirectory.appendingPathComponent(pendingMetadataFileName),
                options: .atomic
            )
            if fileManager.fileExists(atPath: destinationDirectory.path) {
                try fileManager.removeItem(at: destinationDirectory)
            }
            try fileManager.moveItem(at: stagingDirectory, to: destinationDirectory)
            return pending
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            throw error
        }
    }

    static func pendingImport(
        fileManager: FileManager = .default
    ) throws -> SharedPendingPinyinImport? {
        let directory = try pendingImportDirectoryURL(fileManager: fileManager)
        let metadataURL = directory.appendingPathComponent(pendingMetadataFileName)
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let pending = try decoder.decode(
            SharedPendingPinyinImport.self,
            from: Data(contentsOf: metadataURL)
        )
        let snapshotURL = directory.appendingPathComponent(snapshotFileName)
        let actualCount = try validateSnapshot(at: snapshotURL)
        guard actualCount == pending.entryCount else {
            throw SharedPinyinUserDataError.entryCountMismatch
        }
        return pending
    }

    /// Prepares the imported snapshot under Rime's sync directory. This must be
    /// called only while the keyboard has no active Rime session.
    static func preparePendingImportForRime(
        _ pending: SharedPendingPinyinImport,
        fileManager: FileManager = .default
    ) throws {
        let userDataURL = try userDataDirectoryURL(fileManager: fileManager)
        let syncDirectory = userDataURL.appendingPathComponent("sync", isDirectory: true)
        if pending.mode == .replace {
            if fileManager.fileExists(atPath: syncDirectory.path) {
                try fileManager.removeItem(at: syncDirectory)
            }
            if fileManager.fileExists(atPath: userDataURL.path) {
                let children = try fileManager.contentsOfDirectory(
                    at: userDataURL,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                for child in children {
                    let name = child.lastPathComponent
                    if name == "\(dictionaryName).userdb"
                        || name.hasPrefix("\(dictionaryName).userdb.") {
                        try fileManager.removeItem(at: child)
                    }
                }
            }
        }

        let importDirectory = try stagedImportDirectoryURL(
            for: pending,
            fileManager: fileManager
        )
        try fileManager.createDirectory(
            at: importDirectory,
            withIntermediateDirectories: true
        )
        let destinationURL = importDirectory.appendingPathComponent(snapshotFileName)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(
            at: try pendingImportDirectoryURL(fileManager: fileManager)
                .appendingPathComponent(snapshotFileName),
            to: destinationURL
        )
    }

    static func completePendingImport(
        _ pending: SharedPendingPinyinImport,
        fileManager: FileManager = .default
    ) {
        try? fileManager.removeItem(
            at: try stagedImportDirectoryURL(for: pending, fileManager: fileManager)
        )
        guard let current = try? pendingImport(fileManager: fileManager),
              current.id == pending.id else {
            return
        }
        try? fileManager.removeItem(
            at: try pendingImportDirectoryURL(fileManager: fileManager)
        )
    }

    private static func appGroupContainerURL(
        fileManager: FileManager
    ) throws -> URL {
        guard let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: SharedCommandStore.appGroupIdentifier
        ) else {
            throw SharedPinyinUserDataError.appGroupUnavailable
        }
        return containerURL
    }

    private static func privateUserDataDirectoryURL(
        fileManager: FileManager
    ) -> URL {
        fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("RimeUserData", isDirectory: true)
    }

    private static func hasLiveUserDatabase(fileManager: FileManager) throws -> Bool {
        fileManager.fileExists(
            atPath: try userDataDirectoryURL(fileManager: fileManager)
                .appendingPathComponent("\(dictionaryName).userdb", isDirectory: true)
                .path
        )
    }

    private static func currentInstallationSnapshot(
        fileManager: FileManager
    ) throws -> SharedPinyinUserDataSnapshot? {
        guard let installationID = try installationID(fileManager: fileManager) else {
            return nil
        }
        let snapshotURL = try userDataDirectoryURL(fileManager: fileManager)
            .appendingPathComponent("sync", isDirectory: true)
            .appendingPathComponent(installationID, isDirectory: true)
            .appendingPathComponent(snapshotFileName)
        guard fileManager.fileExists(atPath: snapshotURL.path) else {
            return nil
        }
        return SharedPinyinUserDataSnapshot(
            url: snapshotURL,
            entryCount: try validateSnapshot(at: snapshotURL)
        )
    }

    private static func isPortableSnapshotRefreshRequired() -> Bool {
        UserDefaults(
            suiteName: SharedCommandStore.appGroupIdentifier
        )?.bool(forKey: snapshotRefreshRequiredKey) == true
    }

    private static func installationID(fileManager: FileManager) throws -> String? {
        let url = try userDataDirectoryURL(fileManager: fileManager)
            .appendingPathComponent("installation.yaml")
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        for line in text.split(whereSeparator: \.isNewline) {
            let normalized = line.trimmingCharacters(in: .whitespaces)
            guard normalized.hasPrefix("installation_id:") else {
                continue
            }
            let value = normalized
                .dropFirst("installation_id:".count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !value.isEmpty,
                  value != ".",
                  value != "..",
                  !value.contains("/"),
                  !value.contains("\\") else {
                throw SharedPinyinUserDataError.invalidInstallationID
            }
            return value
        }
        return nil
    }

    private static func pendingImportDirectoryURL(
        fileManager: FileManager
    ) throws -> URL {
        try appGroupContainerURL(fileManager: fileManager).appendingPathComponent(
            pendingDirectoryName,
            isDirectory: true
        )
    }

    private static func stagedImportDirectoryURL(
        for pending: SharedPendingPinyinImport,
        fileManager: FileManager
    ) throws -> URL {
        try userDataDirectoryURL(fileManager: fileManager)
            .appendingPathComponent("sync", isDirectory: true)
            .appendingPathComponent(
                "agenboard-import-\(pending.id.uuidString)",
                isDirectory: true
            )
    }
}

private enum SharedPinyinUserDataError: LocalizedError {
    case appGroupUnavailable
    case snapshotNotReady
    case pendingImportNotApplied
    case invalidInstallationID
    case snapshotTooLarge
    case tooManyEntries
    case invalidUTF8
    case invalidHeader
    case wrongDictionary
    case invalidLine
    case entryCountMismatch

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "无法访问 AgenBoard 的共享数据容器。请确认主 App 与键盘扩展使用同一个 App Group 签名。"
        case .snapshotNotReady:
            return "发现已有拼音学习数据，但可读快照尚未生成。请先打开一次 AgenBoard 键盘再返回重试，以免导出遗漏拼音偏好。"
        case .pendingImportNotApplied:
            return "拼音学习记录正在等待 Rime 恢复。请先打开一次 AgenBoard 键盘再返回导出，以免遗漏刚导入的偏好。"
        case .invalidInstallationID:
            return "Rime 安装标识无效，无法安全定位拼音学习快照。"
        case .snapshotTooLarge:
            return "拼音学习快照超过 64 MB 限制。"
        case .tooManyEntries:
            return "拼音学习快照中的记录数量过多。"
        case .invalidUTF8:
            return "拼音学习快照不是有效的 UTF-8 文本。"
        case .invalidHeader:
            return "拼音学习快照缺少有效的 Rime 用户词典头。"
        case .wrongDictionary:
            return "拼音学习快照不属于 AgenBoard 使用的 rime_ice 词典。"
        case .invalidLine:
            return "拼音学习快照包含格式不正确的记录。"
        case .entryCountMismatch:
            return "拼音学习快照的记录数量与导入元数据不一致。"
        }
    }
}
