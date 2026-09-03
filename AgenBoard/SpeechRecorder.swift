import AVFoundation
import Foundation
import Speech
import UIKit

@MainActor
final class SpeechRecorder: ObservableObject {
    private struct RealtimeCoverageAssessment {
        let needsRecovery: Bool
        let score: Double
        let detail: String
    }

    private struct FinalizationJob {
        let id: UUID
        let historyItemID: UUID?
        let audioURL: URL
        let provider: SpeechRecognitionProvider
        let recognitionMode: RecognitionHotwordMode
        let libraryHotwords: [String]
        let activeHotwords: [String]
        let configuredHotwordCount: Int
        let launchRequest: SharedRecordingToggleRequest?
        let deliveryRequest: SharedRecordingToggleRequest?
        let realtimeSession: VolcRealtimeSpeechSession?
        let realtimeAudioSendingTask: Task<Void, Error>?
        let recordingDuration: TimeInterval
        let firstSignificantAudioTime: TimeInterval?
        let lastSignificantAudioTime: TimeInterval?
        let significantAudioDuration: TimeInterval
        let shouldDeliverResultToKeyboard: Bool
    }

    @Published var transcript = ""
    @Published var status = "准备录音"
    @Published private(set) var isPreparingRecording = false
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var isPlaying = false
    @Published var audioLevel = 0.0
    @Published var peakAudioLevel = 0.0
    @Published var currentDecibels = -80.0
    @Published var recordingDuration = 0.0
    @Published var lastRecordingFileSize = 0
    @Published var errorMessage = ""
    @Published var showsError = false

    private let historyStore: RecognitionHistoryStore
    private lazy var recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh_CN"))
    private var recorder: AVAudioRecorder?
    private var realtimeCapture: RealtimeAudioCapture?
    private var realtimeSession: VolcRealtimeSpeechSession?
    private var realtimeConnectionTask: Task<Void, Never>?
    private var realtimeAudioSendingTask: Task<Void, Error>?
    private var livePreviewRecognitionRequest:
        SFSpeechAudioBufferRecognitionRequest?
    private var livePreviewRecognitionTask: SFSpeechRecognitionTask?
    private var realtimeTranscriptIsFinal = false
    private var player: AVAudioPlayer?
    private var recordingURL: URL?
    private var pendingRecordingURL: URL?
    private var recordingStartTask: Task<Void, Never>?
    private var recordingStartID: UUID?
    private var activeSegmentID: UUID?
    private var mostRecentFinalizationJobID: UUID?
    private var pendingKeyboardDeliveryJobID: UUID?
    private var finalizationTasks: [UUID: Task<Void, Never>] = [:]
    private var legacyRecognitionTasks: [UUID: SFSpeechRecognitionTask] = [:]
    private var finalizationBackgroundTaskIDs:
        [UUID: UIBackgroundTaskIdentifier] = [:]
    private var meteringTask: Task<Void, Never>?
    private var playbackStopTask: Task<Void, Never>?
    private var currentLaunchRequest: SharedRecordingToggleRequest?
    private var currentProvider = SpeechRecognitionProvider.apple
    private var currentRecognitionMode = RecognitionHotwordMode.withHotwords
    private var currentLibraryHotwords: [String] = []
    private var currentActiveHotwords: [String] = []
    private var currentConfiguredHotwordCount = 0
    private var smoothedAudioLevel = 0.0
    private var firstSignificantAudioTime: TimeInterval?
    private var lastSignificantAudioTime: TimeInterval?
    private var significantAudioDuration = 0.0
    private var lastRealtimeMeterDuration = 0.0
    private let realtimePacketByteCount = 3_200
    private let realtimeBytesPerSecond = 32_000
    private let significantAudioThresholdDecibels = -42.0
    private let retryableAudioSessionActivationErrorCodes: Set<Int> = [
        560_557_684, // AVAudioSessionErrorCodeCannotInterruptOthers ('!int')
        561_015_905  // AVAudioSessionErrorCodeCannotStartPlaying ('!pla')
    ]

    init(historyStore: RecognitionHistoryStore) {
        self.historyStore = historyStore
    }

    var buttonTitle: String {
        if isPreparingRecording {
            return "正在准备，请稍候"
        }
        return isRecording ? "停止并识别" : "开始录音"
    }

    var buttonIcon: String {
        if isPreparingRecording {
            return "hourglass"
        }
        return isRecording ? "stop.fill" : "mic.fill"
    }

    var canPlayRecording: Bool {
        guard let recordingURL else {
            return false
        }

        return FileManager.default.fileExists(atPath: recordingURL.path)
    }

    var playbackButtonTitle: String {
        isPlaying ? "停止播放" : "播放录音"
    }

    var playbackButtonIcon: String {
        isPlaying ? "stop.circle" : "play.circle"
    }

    var audioDebugText: String {
        "\(Int(currentDecibels.rounded())) dB"
    }

    var recordingInfoText: String {
        if isRecording {
            return String(format: "时长 %.1fs", recordingDuration)
        }

        guard lastRecordingFileSize > 0 else {
            return "还没有录音"
        }

        let kb = Double(lastRecordingFileSize) / 1024.0
        return String(format: "上一段 %.1fs · %.1f KB", recordingDuration, kb)
    }

    func toggleRecording(request: SharedRecordingToggleRequest? = nil) {
        if isRecording {
            stopRecordingAndTranscribe()
        } else {
            startRecordingIfNeeded(request: request)
        }
    }

    func stopRecordingAndTranscribeIfNeeded(
        deliverResultToKeyboard: Bool? = nil,
        request: SharedRecordingToggleRequest? = nil
    ) {
        guard isRecording else {
            return
        }

        stopRecordingAndTranscribe(
            deliverResultToKeyboard: deliverResultToKeyboard,
            deliveryRequest: request
        )
    }

    func startRecordingIfNeeded(request: SharedRecordingToggleRequest? = nil) {
        if isRecording {
            publishRequestResponse(for: request, phase: .recording)
            return
        }

        guard !isPreparingRecording else {
            return
        }

        isPreparingRecording = true
        status = "正在准备语音输入，请看到“可以说话”后再开始"
        publishRecordingSnapshot(status: status)
        publishRequestResponse(
            for: request,
            phase: .preparing,
            message: "正在启动麦克风和豆包实时链路"
        )
        recordingStartTask?.cancel()
        let startID = UUID()
        recordingStartID = startID
        recordingStartTask = Task { [weak self] in
            guard let self else {
                return
            }
            await self.startRecording(request: request)
            guard self.recordingStartID == startID else {
                return
            }
            if self.isPreparingRecording {
                self.isPreparingRecording = false
                self.publishRecordingSnapshot(status: self.status)
            }
            self.recordingStartTask = nil
            self.recordingStartID = nil
        }
    }

    func publishCurrentSnapshot() {
        refreshKeyboardDeliveryStatusIfNeeded()
        publishRecordingSnapshot(status: status)
    }

    private func refreshKeyboardDeliveryStatusIfNeeded() {
        guard status.contains("等待键盘填入"),
              let result = SharedCommandStore.latestRecognitionResult() else {
            return
        }

        if SharedCommandStore.latestInsertedRecognitionResultID() == result.id,
           SharedCommandStore.latestRecognitionResultInsertionAttemptedAt() > 0 {
            status = status.replacingOccurrences(
                of: "等待键盘填入",
                with: "已发送至键盘"
            )
        } else if !SharedCommandStore.isKeyboardAutoInsertPending() {
            status = "识别完成，但未能自动填入；请复制识别结果"
        }
    }

    func clear() {
        let discardedActiveRecordingURL = pendingRecordingURL ?? (
            activeSegmentID == nil ? nil : recordingURL
        )
        if isRecording {
            recorder?.stop()
            recorder = nil
            realtimeCapture?.stop()
            realtimeCapture = nil
            realtimeAudioSendingTask?.cancel()
            realtimeAudioSendingTask = nil
            realtimeSession?.cancel()
            realtimeSession = nil
            isRecording = false
            deactivateAudioSession()
        }

        stopMetering()
        stopPlayback()
        recordingStartTask?.cancel()
        recordingStartTask = nil
        recordingStartID = nil
        realtimeAudioSendingTask?.cancel()
        realtimeAudioSendingTask = nil
        stopAppleLivePreview()
        realtimeSession?.cancel()
        realtimeSession = nil
        realtimeCapture?.stop()
        realtimeCapture = nil
        if let discardedActiveRecordingURL {
            try? FileManager.default.removeItem(
                at: discardedActiveRecordingURL
            )
        }
        activeSegmentID = nil
        pendingKeyboardDeliveryJobID = nil
        recordingURL = nil
        pendingRecordingURL = nil
        isPreparingRecording = false
        refreshFinalizationState()
        transcript = ""
        realtimeTranscriptIsFinal = false
        SharedCommandStore.clearRecognitionResult()
        SharedCommandStore.cancelKeyboardAutoInsert()
        audioLevel = 0
        smoothedAudioLevel = 0
        peakAudioLevel = 0
        currentDecibels = -80
        recordingDuration = 0
        firstSignificantAudioTime = nil
        lastSignificantAudioTime = nil
        significantAudioDuration = 0
        lastRealtimeMeterDuration = 0
        lastRecordingFileSize = 0
        currentLaunchRequest = nil
        status = "准备录音"
        publishRecordingSnapshot(status: status)
    }

    func cancelCurrentRecognition() {
        guard isPreparingRecording || isRecording else {
            return
        }

        let cancelledRecordingURL = isPreparingRecording
            ? pendingRecordingURL
            : recordingURL

        recorder?.stop()
        recorder = nil
        realtimeCapture?.stop()
        realtimeCapture = nil
        realtimeAudioSendingTask?.cancel()
        realtimeAudioSendingTask = nil
        stopAppleLivePreview()
        realtimeSession?.cancel()
        realtimeSession = nil
        recordingStartTask?.cancel()
        recordingStartTask = nil
        recordingStartID = nil
        stopMetering()
        stopPlayback()
        isRecording = false
        isPreparingRecording = false
        refreshFinalizationState()
        deactivateAudioSession()

        var cleanupFailure: Error?
        do {
            if let cancelledRecordingURL,
               FileManager.default.fileExists(atPath: cancelledRecordingURL.path) {
                try FileManager.default.removeItem(at: cancelledRecordingURL)
            }
        } catch {
            cleanupFailure = error
        }

        recordingURL = nil
        pendingRecordingURL = nil
        activeSegmentID = nil
        currentLaunchRequest = nil
        transcript = ""
        realtimeTranscriptIsFinal = false
        SharedCommandStore.clearRecognitionResult()
        SharedCommandStore.cancelKeyboardAutoInsert()
        audioLevel = 0
        smoothedAudioLevel = 0
        peakAudioLevel = 0
        currentDecibels = -80
        recordingDuration = 0
        firstSignificantAudioTime = nil
        lastSignificantAudioTime = nil
        significantAudioDuration = 0
        lastRealtimeMeterDuration = 0
        lastRecordingFileSize = 0
        status = cleanupFailure == nil
            ? "已放弃本段"
            : "已放弃本段，但录音清理失败"
        publishRecordingSnapshot(status: status)
    }

    func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            playLatestRecording()
        }
    }

    private func startRecording(request: SharedRecordingToggleRequest?) async {
        RecordingLaunchMetrics.mark(
            "main_recording_start_entered",
            request: request
        )
        currentProvider = SpeechServicePreferences.provider
        if request == nil {
            // A recording started directly in the containing app must not consume
            // a stale insertion request left by an earlier keyboard session.
            SharedCommandStore.cancelKeyboardAutoInsert()
        }
        if currentProvider.usesVolc {
            do {
                _ = try VolcSpeechConfiguration.load()
            } catch {
                SharedCommandStore.cancelKeyboardAutoInsert()
                let message = "豆包语音配置不可用：\(error.localizedDescription)"
                status = message
                publishRequestResponse(for: request, phase: .failed, message: message)
                showError(message)
                return
            }
        }
        guard !Task.isCancelled else {
            return
        }
        let hasRequiredPermissions = await requestPermissions(
            for: currentProvider
        )
        guard !Task.isCancelled else {
            return
        }
        guard hasRequiredPermissions else {
            RecordingLaunchMetrics.mark(
                "main_recording_permission_denied",
                request: request
            )
            SharedCommandStore.cancelKeyboardAutoInsert()
            status = errorMessage.isEmpty ? "录音权限不可用" : errorMessage
            publishRequestResponse(
                for: request,
                phase: .failed,
                message: status
            )
            return
        }
        RecordingLaunchMetrics.mark(
            "main_recording_permissions_ready",
            request: request
        )
        prepareRecognitionContext()

        currentLaunchRequest = request
        pendingKeyboardDeliveryJobID = nil
        let segmentID = UUID()
        activeSegmentID = segmentID
        transcript = ""
        realtimeTranscriptIsFinal = false
        SharedCommandStore.clearRecognitionResult()
        lastRecordingFileSize = 0
        recordingDuration = 0
        audioLevel = 0
        smoothedAudioLevel = 0
        peakAudioLevel = 0
        currentDecibels = -80
        firstSignificantAudioTime = nil
        lastSignificantAudioTime = nil
        significantAudioDuration = 0
        lastRealtimeMeterDuration = 0
        stopPlayback()

        var startingRecordingURL: URL?
        do {
            try Task.checkCancellation()
            let session = AVAudioSession.sharedInstance()
            try AudioSessionRouting.configureForRecording(session)
            _ = try AudioSessionRouting.applyStoredPreferredInput(to: session)
            try await activateAudioSessionWithRetry(
                session,
                request: request
            )
            try Task.checkCancellation()
            RecordingLaunchMetrics.mark(
                "main_audio_session_active",
                request: request
            )

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("agenboard-\(UUID().uuidString)")
                .appendingPathExtension("m4a")
            startingRecordingURL = url
            pendingRecordingURL = url

            if currentProvider == .volcRealtime {
                try await startVolcRealtimeCapture(
                    at: url,
                    segmentID: segmentID,
                    request: request
                )
            } else if currentProvider == .apple {
                try startAppleRealtimePreviewCapture(
                    at: url,
                    segmentID: segmentID
                )
            } else {
                let settings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                ]

                let recorder = try AVAudioRecorder(url: url, settings: settings)
                recorder.isMeteringEnabled = true
                recorder.prepareToRecord()
                try Task.checkCancellation()

                guard recorder.record() else {
                    SharedCommandStore.cancelKeyboardAutoInsert()
                    discardStartingRecording(startingRecordingURL)
                    deactivateAudioSession()
                    status = "录音启动失败"
                    publishRequestResponse(
                        for: request,
                        phase: .failed,
                        message: "录音启动失败"
                    )
                    showError("录音启动失败。")
                    return
                }
                self.recorder = recorder
            }

            recordingURL = url
            pendingRecordingURL = nil
            isPreparingRecording = false
            isRecording = true
            status = currentProvider == .volcRealtime
                ? "可以说话 · 正在录音（实时连接中…）"
                : "可以说话 · 正在录音"
            publishRecordingSnapshot(status: status)
            startMetering()
            RecordingLaunchMetrics.mark(
                "main_recorder_started",
                request: request
            )
            publishRequestResponse(for: request, phase: .recording)
        } catch is CancellationError {
            realtimeConnectionTask?.cancel()
            realtimeConnectionTask = nil
            realtimeAudioSendingTask?.cancel()
            realtimeAudioSendingTask = nil
            stopAppleLivePreview()
            realtimeCapture?.stop()
            realtimeCapture = nil
            realtimeSession?.cancel()
            realtimeSession = nil
            if activeSegmentID == segmentID {
                activeSegmentID = nil
            }
            recorder?.stop()
            recorder = nil
            discardStartingRecording(
                startingRecordingURL
            )
            deactivateAudioSession()
        } catch {
            realtimeConnectionTask?.cancel()
            realtimeConnectionTask = nil
            realtimeAudioSendingTask?.cancel()
            realtimeAudioSendingTask = nil
            stopAppleLivePreview()
            realtimeCapture?.stop()
            realtimeCapture = nil
            realtimeSession?.cancel()
            realtimeSession = nil
            if activeSegmentID == segmentID {
                activeSegmentID = nil
            }
            recorder?.stop()
            recorder = nil
            discardStartingRecording(
                startingRecordingURL
            )
            deactivateAudioSession()
            guard !Task.isCancelled else {
                return
            }
            isPreparingRecording = false
            let nsError = error as NSError
            status = "录音启动失败"
            RecordingLaunchMetrics.mark(
                "main_recorder_start_failed",
                request: request,
                detail: "domain=\(nsError.domain) code=\(nsError.code) \(nsError.localizedDescription)"
            )
            SharedCommandStore.cancelKeyboardAutoInsert()
            let message = "无法开始录音：\(error.localizedDescription)"
            publishRequestResponse(for: request, phase: .failed, message: message)
            showError(message)
        }
    }

    private func discardStartingRecording(_ url: URL?) {
        guard let url else {
            return
        }
        if pendingRecordingURL == url {
            pendingRecordingURL = nil
        }
        // 关键资产保护：若文件存在且包含有效音频（超过 1KB），绝不静默删除，而是救援归档至历史记录供用户恢复
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64, size > 1_024 {
            _ = try? historyStore.archiveRecording(
                at: url,
                duration: max(0.5, recordingDuration),
                originalMode: currentRecognitionMode,
                originalProvider: currentProvider
            )
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    private func withThrowingTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw VolcSpeechServiceError.timeout("连接超时（\(String(format: "%.1f", seconds)) 秒未响应）")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func prepareRecognitionContext() {
        currentRecognitionMode = RecognitionPreferences.usesHotwords
            ? .withHotwords
            : .withoutHotwords
        let libraryEntries = HotwordLibraryStorage.loadEntries()
        currentLibraryHotwords = libraryEntries.map(\.term)
        currentActiveHotwords = currentRecognitionMode == .withHotwords
            ? HotwordSelectionPolicy.selectedTerms(
                from: libraryEntries,
                provider: SpeechServicePreferences.provider
            )
            : []
        currentConfiguredHotwordCount = currentActiveHotwords.count
    }

    private func startVolcRealtimeCapture(
        at url: URL,
        segmentID: UUID,
        request: SharedRecordingToggleRequest?
    ) async throws {
        // 麦克风是唯一不能事后补回的输入，优先保证本地秒开与持续安全落盘。
        // 音频帧通过无界 AsyncStream 完整缓存，云端 WebSocket 异步建立并在后台按需推流追赶，
        // 遇到无网、欠费或连接超时时绝不阻塞或打断本地录音。
        status = "正在启动麦克风"
        publishRecordingSnapshot(status: status)

        let (audioStream, continuation) = AsyncStream<Data>.makeStream(
            bufferingPolicy: .unbounded
        )
        let capture = try RealtimeAudioCapture(
            fileURL: url,
            audioContinuation: continuation
        ) { [weak self] decibels, duration in
            self?.updateRealtimeMeter(decibels: decibels, duration: duration)
        }
        realtimeCapture = capture
        do {
            try capture.start()
        } catch {
            capture.stop()
            realtimeCapture = nil
            throw error
        }
        RecordingLaunchMetrics.mark(
            "main_realtime_capture_started",
            request: request
        )

        // 异步建立豆包实时链路，解耦云端握手与本地麦克风
        realtimeConnectionTask?.cancel()
        realtimeConnectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.connectAndStreamVolcRealtime(
                audioStream: audioStream,
                capture: capture,
                segmentID: segmentID,
                request: request
            )
        }
    }

    private func connectAndStreamVolcRealtime(
        audioStream: AsyncStream<Data>,
        capture: RealtimeAudioCapture,
        segmentID: UUID,
        request: SharedRecordingToggleRequest?
    ) async {
        guard activeSegmentID == segmentID, isRecording || isPreparingRecording else {
            return
        }

        let config: VolcSpeechConfiguration
        do {
            config = try VolcSpeechConfiguration.load()
        } catch {
            guard activeSegmentID == segmentID, isRecording else { return }
            status = "正在本地录音 · 豆包配置不可用"
            publishRecordingSnapshot(status: status)
            return
        }

        let session = VolcRealtimeSpeechSession(
            configuration: config,
            hotwords: currentActiveHotwords,
            transcriptionMode: SpeechServicePreferences.volcRealtimeTranscriptionMode,
            launchRequest: request
        ) { [weak self] text, isFinal in
            guard let self,
                  self.activeSegmentID == segmentID,
                  self.isPreparingRecording || self.isRecording else {
                return
            }
            self.transcript = SpeechTranscriptNormalizer.normalize(text)
            self.realtimeTranscriptIsFinal = isFinal
            if self.isPreparingRecording {
                self.status = "正在准备 · 豆包已收到缓存音频"
            } else {
                self.status = isFinal
                    ? "正在录音 · 豆包已生成确定句"
                    : "正在录音 · 豆包实时转写中"
            }
            self.publishRecordingSnapshot(status: self.status)
        }

        do {
            try await withThrowingTimeout(seconds: 3.5) {
                try await session.connect()
            }
            guard activeSegmentID == segmentID, isRecording || isPreparingRecording else {
                session.cancel()
                return
            }
            realtimeSession = session
            RecordingLaunchMetrics.mark(
                "main_realtime_connection_ready",
                request: request
            )
            if isRecording {
                status = "正在录音 · 豆包实时链路已就绪"
                publishRecordingSnapshot(status: status)
            }

            realtimeAudioSendingTask = Task { @MainActor [weak self, session, capture] in
                guard let self else { throw CancellationError() }
                do {
                    try await self.sendVolcRealtimeAudioStream(
                        audioStream,
                        to: session,
                        capture: capture,
                        request: request
                    )
                } catch {
                    if !Task.isCancelled,
                       self.isPreparingRecording || self.isRecording {
                        self.status = "正在本地录音 · 实时识别已中断（录音继续中）"
                        self.publishRecordingSnapshot(status: self.status)
                    }
                    throw error
                }
            }
        } catch {
            guard activeSegmentID == segmentID, isRecording || isPreparingRecording else {
                session.cancel()
                return
            }
            // 核心容错：网络断开、超时或欠费只影响实时转写，绝对不中断本地麦克风录制！
            session.cancel()
            realtimeSession = nil
            if isRecording {
                status = "正在本地录音 · 网络未连接，实时转写暂不可用"
                publishRecordingSnapshot(status: status)
            }
        }
    }

    private func startAppleRealtimePreviewCapture(
        at url: URL,
        segmentID: UUID
    ) throws {
        let recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
        if let recognizer, recognizer.isAvailable {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.contextualStrings = HotwordSelectionPolicy.limitedTerms(
                currentActiveHotwords
            )
            request.addsPunctuation = true
            recognitionRequest = request
            livePreviewRecognitionRequest = request
            livePreviewRecognitionTask = recognizer.recognitionTask(
                with: request
            ) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.activeSegmentID == segmentID,
                          self.isPreparingRecording || self.isRecording else {
                        return
                    }
                    if let result {
                        let text = SpeechTranscriptNormalizer.normalize(
                            result.bestTranscription.formattedString
                        )
                        if !text.isEmpty {
                            self.transcript = text
                            self.realtimeTranscriptIsFinal = result.isFinal
                            self.status = result.isFinal
                                ? "正在录音 · 已生成实时句子"
                                : "正在录音 · 实时转写中"
                            self.publishRecordingSnapshot(status: self.status)
                        }
                    } else if error != nil {
                        // 实时预览失败不应中断录音；停止后仍会用完整音频
                        // 走正式识别，保证本段内容可以正常保存和插入。
                        self.status = "正在录音 · 实时预览暂不可用"
                        self.publishRecordingSnapshot(status: self.status)
                    }
                }
            }
        } else {
            recognitionRequest = nil
        }

        do {
            let capture = try RealtimeAudioCapture(
                fileURL: url,
                audioBufferHandler: { [weak recognitionRequest] buffer in
                    recognitionRequest?.append(buffer)
                }
            ) { [weak self] decibels, duration in
                self?.updateRealtimeMeter(decibels: decibels, duration: duration)
            }
            realtimeCapture = capture
            try capture.start()
        } catch {
            stopAppleLivePreview()
            realtimeCapture?.stop()
            realtimeCapture = nil
            throw error
        }
    }

    private func stopAppleLivePreview() {
        livePreviewRecognitionRequest?.endAudio()
        livePreviewRecognitionRequest = nil
        livePreviewRecognitionTask?.cancel()
        livePreviewRecognitionTask = nil
    }

    private func waitForRealtimeFirstAudioFrame(
        capture: RealtimeAudioCapture,
        request: SharedRecordingToggleRequest?
    ) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while capture.capturedPCMByteCount == 0 {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw VolcSpeechServiceError.timeout(
                    "麦克风已启动，但没有收到有效音频帧。"
                )
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        RecordingLaunchMetrics.mark(
            "main_realtime_first_audio_ready",
            request: request,
            detail: "captured_pcm_bytes=\(capture.capturedPCMByteCount)"
        )
    }

    private func sendVolcRealtimeAudioStream(
        _ audioStream: AsyncStream<Data>,
        to session: VolcRealtimeSpeechSession,
        capture: RealtimeAudioCapture,
        request: SharedRecordingToggleRequest?
    ) async throws {
        var pending = Data()
        var capturedByteCount = 0
        var speechPacketByteCount = 0
        var maximumBacklog = 0.0
        var lastPacketSentAt: Date?

        func targetPacketInterval(backlog: TimeInterval) -> TimeInterval {
            if backlog > 1 {
                return 0.1 / 1.5
            }
            if backlog > 0.35 {
                return 0.1 / 1.25
            }
            return 0.1
        }

        func sendPacket(_ packet: Data) async throws {
            let sourceCapturedByteCount = capture.capturedPCMByteCount
            let backlog = max(
                0,
                Double(sourceCapturedByteCount - speechPacketByteCount)
                    / Double(realtimeBytesPerSecond)
            )
            maximumBacklog = max(maximumBacklog, backlog)

            if let lastPacketSentAt {
                let delay = targetPacketInterval(backlog: backlog)
                    - Date().timeIntervalSince(lastPacketSentAt)
                if delay > 0 {
                    try await Task.sleep(
                        nanoseconds: UInt64(delay * 1_000_000_000)
                    )
                }
            }
            try await session.sendAudio(packet)
            speechPacketByteCount += packet.count
            lastPacketSentAt = Date()
        }

        for await data in audioStream {
            try Task.checkCancellation()
            capturedByteCount += data.count
            pending.append(data)
            while pending.count >= realtimePacketByteCount {
                let packet = Data(
                    pending.prefix(realtimePacketByteCount)
                )
                pending.removeFirst(realtimePacketByteCount)
                try await sendPacket(packet)
            }
        }

        // 麦克风回调块大小由硬件决定。最后不足 100 ms 的部分只补零，
        // 不丢弃任何真实采样，并保证服务端收到均匀的 3,200 字节帧。
        if !pending.isEmpty {
            pending.append(
                Data(count: realtimePacketByteCount - pending.count)
            )
            try await sendPacket(pending)
        }

        let paddingByteCount = speechPacketByteCount - capturedByteCount
        let sourceCapturedByteCount = capture.capturedPCMByteCount
        guard capturedByteCount == sourceCapturedByteCount,
              paddingByteCount >= 0,
              paddingByteCount < realtimePacketByteCount else {
            throw VolcSpeechServiceError.invalidResponse(
                "实时音频完整性校验失败：采集与发送字节数不一致。"
            )
        }

        RecordingLaunchMetrics.mark(
            "main_realtime_audio_stream_drained",
            request: request,
            detail: [
                "captured_bytes=\(capturedByteCount)",
                "source_captured_bytes=\(sourceCapturedByteCount)",
                "framed_speech_bytes=\(speechPacketByteCount)",
                "frame_padding_bytes=\(paddingByteCount)",
                String(
                    format: "maximum_backlog_ms=%.1f",
                    maximumBacklog * 1_000
                ),
                "invariant=passed"
            ].joined(separator: " ")
        )
    }

    private func activateAudioSessionWithRetry(
        _ session: AVAudioSession,
        request: SharedRecordingToggleRequest?
    ) async throws {
        for attempt in 1...5 {
            do {
                try session.setActive(true)
                return
            } catch {
                let nsError = error as NSError
                guard retryableAudioSessionActivationErrorCodes.contains(
                    nsError.code
                ), attempt < 5 else {
                    throw error
                }

                RecordingLaunchMetrics.mark(
                    "main_audio_session_activation_retry",
                    request: request,
                    detail: "attempt=\(attempt) code=\(nsError.code)"
                )
                try await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    private func stopRecordingAndTranscribe(
        deliverResultToKeyboard: Bool? = nil,
        deliveryRequest: SharedRecordingToggleRequest? = nil
    ) {
        let segmentID = activeSegmentID ?? UUID()
        let sourceRecordingURL = recordingURL
        let capturedRealtimeSession = realtimeSession
        let capturedAudioSendingTask = realtimeAudioSendingTask
        let capturedLiveTranscript = transcript
        let capturedProvider = currentProvider
        let capturedRecognitionMode = currentRecognitionMode
        let capturedLibraryHotwords = currentLibraryHotwords
        let capturedActiveHotwords = currentActiveHotwords
        let capturedConfiguredHotwordCount = currentConfiguredHotwordCount
        let capturedLaunchRequest = currentLaunchRequest
        let capturedRecordingDuration = recordingDuration
        let capturedFirstSignificantAudioTime = firstSignificantAudioTime
        let capturedLastSignificantAudioTime = lastSignificantAudioTime
        let capturedSignificantAudioDuration = significantAudioDuration
        let shouldDeliverResultToKeyboard = deliverResultToKeyboard
            ?? SharedCommandStore.isKeyboardAutoInsertPending()

        if currentProvider == .volcRealtime || currentProvider == .apple {
            if let realtimeCapture {
                realtimeCapture.stop()
                recordingDuration = max(
                    recordingDuration,
                    Double(realtimeCapture.capturedPCMByteCount)
                        / Double(realtimeBytesPerSecond)
                )
            }
            realtimeCapture = nil
            if currentProvider == .apple {
                stopAppleLivePreview()
            }
        } else {
            recorder?.stop()
        }
        updateLastRecordingStats()
        stopMetering()
        recorder = nil
        isRecording = false
        deactivateAudioSession()

        var archivedRecordingURL = sourceRecordingURL
        var historyItemID: UUID?
        if let sourceRecordingURL {
            do {
                let archived = try historyStore.archiveRecording(
                    at: sourceRecordingURL,
                    duration: recordingDuration,
                    originalMode: capturedRecognitionMode,
                    originalProvider: capturedProvider
                )
                self.recordingURL = archived.audioURL
                archivedRecordingURL = archived.audioURL
                historyItemID = archived.id
                try historyStore.storeTranscriptionSnapshot(
                    itemID: archived.id,
                    mode: capturedRecognitionMode,
                    transcript: capturedLiveTranscript
                )
            } catch {
                showError("录音历史保存失败，但仍会继续识别：\(error.localizedDescription)")
            }
        }

        realtimeConnectionTask?.cancel()
        realtimeConnectionTask = nil
        realtimeSession = nil
        realtimeAudioSendingTask = nil
        currentLaunchRequest = nil
        activeSegmentID = nil

        guard let archivedRecordingURL else {
            status = "录音已停止，但没有找到录音文件"
            publishRecordingSnapshot(status: status)
            return
        }

        let job = FinalizationJob(
            id: segmentID,
            historyItemID: historyItemID,
            audioURL: archivedRecordingURL,
            provider: capturedProvider,
            recognitionMode: capturedRecognitionMode,
            libraryHotwords: capturedLibraryHotwords,
            activeHotwords: capturedActiveHotwords,
            configuredHotwordCount: capturedConfiguredHotwordCount,
            launchRequest: capturedLaunchRequest,
            deliveryRequest: deliveryRequest,
            realtimeSession: capturedRealtimeSession,
            realtimeAudioSendingTask: capturedAudioSendingTask,
            recordingDuration: max(
                capturedRecordingDuration,
                recordingDuration
            ),
            firstSignificantAudioTime: capturedFirstSignificantAudioTime,
            lastSignificantAudioTime: capturedLastSignificantAudioTime,
            significantAudioDuration: capturedSignificantAudioDuration,
            shouldDeliverResultToKeyboard: shouldDeliverResultToKeyboard
        )
        if shouldDeliverResultToKeyboard {
            pendingKeyboardDeliveryJobID = job.id
        }
        mostRecentFinalizationJobID = job.id
        beginFinalizationBackgroundTask(for: job)
        finalizationTasks[job.id] = Task { [weak self] in
            await self?.runFinalization(job)
        }
        refreshFinalizationState()
        status = "本段已保存 · 正在后台整理，可继续说话"
        publishRecordingSnapshot(status: status)
    }

    private func publishRequestResponse(
        for request: SharedRecordingToggleRequest?,
        phase: SharedRecordingRequestPhase,
        message: String = ""
    ) {
        guard let request else {
            return
        }
        SharedCommandStore.updateRecordingRequestResponse(
            for: request,
            phase: phase,
            message: message
        )
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    private func beginFinalizationBackgroundTask(for job: FinalizationJob) {
        let taskID = UIApplication.shared.beginBackgroundTask(
            withName: "Speech finalization \(job.id.uuidString)"
        ) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                self.finalizationTasks[job.id]?.cancel()
                self.legacyRecognitionTasks[job.id]?.cancel()
                job.realtimeSession?.cancel()
                self.failFinalization(
                    job,
                    message: "后台整理时间不足，已保留录音，可从识别历史重新转写。",
                    presentsError: false
                )
                self.finishFinalization(job)
            }
        }
        finalizationBackgroundTaskIDs[job.id] = taskID
    }

    private func endFinalizationBackgroundTask(for jobID: UUID) {
        guard let taskID = finalizationBackgroundTaskIDs.removeValue(
            forKey: jobID
        ), taskID != .invalid else {
            return
        }
        UIApplication.shared.endBackgroundTask(taskID)
    }

    private func runFinalization(_ job: FinalizationJob) async {
        switch job.provider {
        case .aliyun, .aliyunRealtime:
            failFinalization(
                job,
                message: "旧版阿里云识别已停用，请重新使用豆包实时识别。",
                presentsError: true
            )
            finishFinalization(job)
        case .volcRealtime:
            await finishVolcRealtimeFinalization(job)
        case .apple:
            if #available(iOS 26.0, *) {
                await finishAppleFinalization(job)
            } else {
                startLegacyAppleFinalization(job)
            }
        }
    }

    private func finishVolcRealtimeFinalization(
        _ job: FinalizationJob
    ) async {
        defer {
            job.realtimeAudioSendingTask?.cancel()
            finishFinalization(job)
        }

        do {
            if let audioSendingTask = job.realtimeAudioSendingTask {
                try await audioSendingTask.value
            }
            try Task.checkCancellation()
            guard let session = job.realtimeSession else {
                updateFinalizationStatus(
                    job,
                    message: "本段录音已保存至历史 · 网络未连接，可在恢复后重试转写"
                )
                failFinalization(
                    job,
                    message: "网络未连接，录音已完整保存，恢复网络后可重试转写。",
                    presentsError: false
                )
                return
            }
            updateFinalizationStatus(
                job,
                message: "本段已保存 · 正在请求豆包二遍终稿"
            )

            var output = try await session.finish()
            try Task.checkCancellation()
            var recoveryNote: String?
            let primaryAssessment = assessRealtimeCoverage(
                output.serviceOutput,
                job: job
            )
            RecordingLaunchMetrics.mark(
                primaryAssessment.needsRecovery
                    ? "main_realtime_coverage_incomplete"
                    : "main_realtime_coverage_complete",
                request: job.launchRequest,
                detail: primaryAssessment.detail
            )

            if primaryAssessment.needsRecovery {
                updateFinalizationStatus(
                    job,
                    message: "本段结果可能不完整 · 正在从录音缓存恢复"
                )
                let recoveryStartedAt = Date()
                do {
                    let recovered = try await VolcRealtimeSpeechTranscriber.transcribe(
                        audioURL: job.audioURL,
                        hotwords: job.activeHotwords,
                        playbackRate: 5.0,
                        launchRequest: job.launchRequest
                    ) { [weak self] progress in
                        self?.updateFinalizationStatus(job, message: progress)
                    }
                    let recoveredAssessment = assessRealtimeCoverage(
                        recovered.serviceOutput,
                        job: job
                    )
                    let usedRecovered = recoveredAssessment.score
                        > primaryAssessment.score
                    if usedRecovered {
                        output = recovered
                    }
                    let recoveryElapsed = Date().timeIntervalSince(
                        recoveryStartedAt
                    )
                    recoveryNote = usedRecovered
                        ? String(format: "缓存恢复成功 %.2fs", recoveryElapsed)
                        : String(format: "缓存复核完成 %.2fs", recoveryElapsed)
                    RecordingLaunchMetrics.mark(
                        "main_realtime_recovery_finished",
                        request: job.launchRequest,
                        detail: [
                            "selected=\(usedRecovered ? "recovered" : "primary")",
                            "primary={\(primaryAssessment.detail)}",
                            "recovered={\(recoveredAssessment.detail)}"
                        ].joined(separator: " ")
                    )
                } catch {
                    let nsError = error as NSError
                    recoveryNote = "缓存恢复未完成"
                    RecordingLaunchMetrics.mark(
                        "main_realtime_recovery_failed",
                        request: job.launchRequest,
                        detail: "domain=\(nsError.domain) code=\(nsError.code) \(nsError.localizedDescription)"
                    )
                }
            }

            var notes = [
                String(
                    format: "停止后等待 %.2fs · 连接 %.2fs",
                    output.metrics.finalizationElapsed,
                    output.metrics.connectionElapsed
                )
            ]
            if let firstResultElapsed = output.metrics.firstResultElapsed {
                notes.append(String(format: "首字 %.2fs", firstResultElapsed))
            }
            if let billedDurationSeconds = output.metrics.billedDurationSeconds {
                notes.append("云端计费 \(billedDurationSeconds)s")
            }
            if let recoveryNote {
                notes.append(recoveryNote)
            }
            if !output.serviceOutput.ignoredHotwords.isEmpty {
                notes.append(
                    "另有 \(output.serviceOutput.ignoredHotwords.count) 个词超出豆包请求级热词限制"
                )
            }
            completeFinalization(
                job,
                text: output.serviceOutput.transcript,
                elapsed: output.metrics.finalizationElapsed,
                provider: .volcRealtime,
                configuredHotwordCount:
                    output.serviceOutput.configuredHotwordCount,
                words: output.serviceOutput.words,
                realtimeMetrics: output.metrics,
                completionNote: "；" + notes.joined(separator: " · ")
            )
        } catch is CancellationError {
            job.realtimeSession?.cancel()
        } catch {
            job.realtimeSession?.cancel()
            let errorMsg = error.localizedDescription
            let isNetworkError = errorMsg.contains("网络") || errorMsg.contains("连接") || errorMsg.contains("超时") || errorMsg.contains("The Internet connection appears to be offline") || errorMsg.contains("timed out")
            let friendlyMessage = isNetworkError
                ? "网络连接异常，录音已完整保存，恢复网络后可重试转写。"
                : "豆包实时识别未完成：\(errorMsg)"
            failFinalization(
                job,
                message: friendlyMessage,
                presentsError: !isNetworkError
            )
        }
    }

    private func assessRealtimeCoverage(
        _ output: SpeechRecognitionServiceOutput,
        job: FinalizationJob
    ) -> RealtimeCoverageAssessment {
        let normalizedTranscript = output.transcript.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let recordingEnd = max(
            job.recordingDuration,
            job.lastSignificantAudioTime ?? 0
        )
        let speechStart = job.firstSignificantAudioTime ?? 0
        let speechEnd = job.lastSignificantAudioTime ?? recordingEnd
        let speechSpan = max(0, speechEnd - speechStart)
        let firstWord = output.words.map(\.beginTimeMilliseconds).min()
            .map { Double($0) / 1_000 }
        let lastWord = output.words.map(\.endTimeMilliseconds).max()
            .map { Double($0) / 1_000 }
        let hasWordTiming = firstWord != nil && lastWord != nil
        let prefixGap = firstWord.map {
            max(0, $0 - speechStart)
        } ?? 0
        let suffixGap = lastWord.map {
            max(0, speechEnd - $0)
        } ?? 0
        let recognizedSpan: TimeInterval
        if let firstWord, let lastWord {
            recognizedSpan = max(0, lastWord - firstWord)
        } else {
            recognizedSpan = 0
        }
        let coverage: Double
        if hasWordTiming, speechSpan > 0 {
            coverage = min(1, recognizedSpan / speechSpan)
        } else {
            // SeedASR 的部分响应只包含整句文本，不保证附带词级时间戳。
            // 此时不能把“没有时间戳”等同于“只识别了 0%”，否则长录音会无谓重试。
            coverage = normalizedTranscript.isEmpty ? 0 : 1
        }
        var reasons: [String] = []
        if normalizedTranscript.isEmpty, job.significantAudioDuration > 0.5 {
            reasons.append("empty_transcript")
        }
        if hasWordTiming, speechSpan > 4, coverage < 0.35 {
            reasons.append("low_coverage")
        }
        if hasWordTiming, speechSpan > 4, prefixGap > 3.5, coverage < 0.65 {
            reasons.append("prefix_gap")
        }
        if hasWordTiming, speechSpan > 4, suffixGap > 3.5, coverage < 0.65 {
            reasons.append("suffix_gap")
        }

        let score = Double(normalizedTranscript.count * 2)
            + Double(output.words.count)
            + coverage * 100
            - prefixGap * 12
            - suffixGap * 12
        let detail = [
            "needs_recovery=\(reasons.isEmpty ? 0 : 1)",
            "reasons=\(reasons.isEmpty ? "none" : reasons.joined(separator: ","))",
            String(format: "recording_end=%.3f", recordingEnd),
            String(format: "speech_start=%.3f", speechStart),
            String(format: "speech_end=%.3f", speechEnd),
            String(format: "recognized_start=%.3f", firstWord ?? -1),
            String(format: "recognized_end=%.3f", lastWord ?? -1),
            "has_word_timing=\(hasWordTiming ? 1 : 0)",
            String(format: "coverage=%.3f", coverage),
            "chars=\(normalizedTranscript.count)",
            "words=\(output.words.count)"
        ].joined(separator: " ")
        return RealtimeCoverageAssessment(
            needsRecovery: !reasons.isEmpty,
            score: score,
            detail: detail
        )
    }

    @available(iOS 26.0, *)
    private func finishAppleFinalization(_ job: FinalizationJob) async {
        defer {
            finishFinalization(job)
        }
        do {
            updateFinalizationStatus(job, message: "本段已保存 · 正在准备中文识别模型")
            let locale = try await AppleSpeechTranscriber.prepareLocale()
            updateFinalizationStatus(job, message: "本段已保存 · 正在后台识别")
            let output = try await AppleSpeechTranscriber.transcribe(
                audioURL: job.audioURL,
                locale: locale,
                hotwords: job.activeHotwords
            )
            try Task.checkCancellation()
            completeFinalization(
                job,
                text: output.transcript,
                elapsed: output.elapsed,
                provider: .apple,
                configuredHotwordCount: job.configuredHotwordCount,
                words: []
            )
        } catch is CancellationError {
            return
        } catch {
            failFinalization(
                job,
                message: "识别失败：\(error.localizedDescription)",
                presentsError: true
            )
        }
    }

    private func startLegacyAppleFinalization(_ job: FinalizationJob) {
        guard let recognizer else {
            failFinalization(
                job,
                message: "当前设备不支持中文语音识别。",
                presentsError: true
            )
            finishFinalization(job)
            return
        }
        guard recognizer.isAvailable else {
            failFinalization(
                job,
                message: "Apple Speech 当前不可用，请稍后再试。",
                presentsError: true
            )
            finishFinalization(job)
            return
        }

        let request = SFSpeechURLRecognitionRequest(url: job.audioURL)
        request.shouldReportPartialResults = false
        request.contextualStrings = HotwordSelectionPolicy.limitedTerms(
            job.activeHotwords
        )
        request.addsPunctuation = true
        let startedAt = Date()
        updateFinalizationStatus(job, message: "本段已保存 · 正在后台识别")

        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self,
                      self.finalizationTasks[job.id] != nil else {
                    return
                }
                if let error {
                    self.failFinalization(
                        job,
                        message: "识别失败：\(error.localizedDescription)",
                        presentsError: true
                    )
                    self.finishFinalization(job)
                    return
                }
                guard let result, result.isFinal else {
                    return
                }
                self.completeFinalization(
                    job,
                    text: result.bestTranscription.formattedString,
                    elapsed: Date().timeIntervalSince(startedAt),
                    provider: .apple,
                    configuredHotwordCount: job.configuredHotwordCount,
                    words: []
                )
                self.finishFinalization(job)
            }
        }
        legacyRecognitionTasks[job.id] = task
    }

    private func completeFinalization(
        _ job: FinalizationJob,
        text: String,
        elapsed: TimeInterval,
        provider: SpeechRecognitionProvider,
        configuredHotwordCount: Int,
        words: [SpeechRecognitionWord],
        fileMetrics: LegacyFileRecognitionMetrics? = nil,
        realtimeMetrics: RealtimeRecognitionMetrics? = nil,
        completionNote: String = ""
    ) {
        let normalizedTranscript = SpeechTranscriptNormalizer.normalize(
            text,
            replacementRules: ReplacementLibraryStorage.loadRules()
        )
        let matchedTerms = HotwordTranscriptMatcher.matches(
            in: normalizedTranscript,
            hotwords: job.libraryHotwords
        )
        HotwordLibraryStorage.markTermsUsed(matchedTerms)

        if let historyItemID = job.historyItemID {
            do {
                try historyStore.storeTranscription(
                    itemID: historyItemID,
                    mode: job.recognitionMode,
                    transcript: normalizedTranscript,
                    elapsed: elapsed,
                    configuredHotwordCount: configuredHotwordCount,
                    matchedTerms: matchedTerms,
                    provider: provider,
                    words: words,
                    fileMetrics: fileMetrics,
                    realtimeMetrics: realtimeMetrics
                )
            } catch {
                failFinalization(
                    job,
                    message: "识别已完成，但历史转写保存失败：\(error.localizedDescription)",
                    presentsError: true
                )
                return
            }
        }

        let isVisibleJob = mostRecentFinalizationJobID == job.id
            && !isRecording
            && !isPreparingRecording
        if isVisibleJob {
            transcript = normalizedTranscript
            realtimeTranscriptIsFinal = true
        }

        let baseStatus = "识别完成 · \(provider.shortTitle)\(completionNote)"
        if let deliveryRequest = job.deliveryRequest,
           !normalizedTranscript.isEmpty {
            SharedCommandStore.publishFinalizedSegmentResult(
                segmentID: job.id.uuidString,
                stopRequest: deliveryRequest,
                text: normalizedTranscript
            )
        }
        let shouldDeliverResult = job.shouldDeliverResultToKeyboard
            && pendingKeyboardDeliveryJobID == job.id
            && isVisibleJob
            && (job.deliveryRequest.map {
                abs(
                    SharedCommandStore.latestKeyboardAutoInsertRequestedAt()
                        - $0.requestedAt
                ) < 0.5
            } ?? true)
        if normalizedTranscript.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty {
            if shouldDeliverResult {
                pendingKeyboardDeliveryJobID = nil
                SharedCommandStore.cancelKeyboardAutoInsert()
            }
            if isVisibleJob {
                status = "未识别到文字"
            }
        } else if shouldDeliverResult {
            pendingKeyboardDeliveryJobID = nil
            if SharedCommandStore.publishRecognitionResult(
                normalizedTranscript
            ) != nil {
                status = SharedCommandStore.isKeyboardAutoInsertPending()
                    ? "\(baseStatus) · 等待键盘填入"
                    : baseStatus
            } else {
                status = "识别完成，但无法发送到键盘"
                showError(
                    "识别已经完成，但无法写入键盘共享数据。请复制识别结果后重试。"
                )
            }
        } else if isVisibleJob {
            status = baseStatus
        }

        if isVisibleJob {
            publishRecordingSnapshot(status: status)
        }
    }

    private func failFinalization(
        _ job: FinalizationJob,
        message: String,
        presentsError: Bool
    ) {
        if let historyItemID = job.historyItemID {
            historyStore.storeFailure(
                itemID: historyItemID,
                mode: job.recognitionMode,
                provider: job.provider,
                message: message
            )
        }
        let isVisibleJob = mostRecentFinalizationJobID == job.id
            && !isRecording
            && !isPreparingRecording
        if job.shouldDeliverResultToKeyboard,
           pendingKeyboardDeliveryJobID == job.id,
           isVisibleJob {
            pendingKeyboardDeliveryJobID = nil
            SharedCommandStore.cancelKeyboardAutoInsert()
        }
        guard isVisibleJob else {
            return
        }
        status = message
        publishRecordingSnapshot(status: status)
        if presentsError {
            showError(message)
        }
    }

    private func updateFinalizationStatus(
        _ job: FinalizationJob,
        message: String
    ) {
        guard mostRecentFinalizationJobID == job.id,
              !isRecording,
              !isPreparingRecording else {
            return
        }
        status = message
        publishRecordingSnapshot(status: status)
    }

    private func finishFinalization(_ job: FinalizationJob) {
        guard finalizationTasks.removeValue(forKey: job.id) != nil else {
            return
        }
        legacyRecognitionTasks.removeValue(forKey: job.id)?.cancel()
        endFinalizationBackgroundTask(for: job.id)
        refreshFinalizationState()
        if !isRecording, !isPreparingRecording {
            publishRecordingSnapshot(status: status)
        }
    }

    private func refreshFinalizationState() {
        isTranscribing = !finalizationTasks.isEmpty
    }

    private func requestPermissions(for provider: SpeechRecognitionProvider) async -> Bool {
        if provider == .apple {
            let speechGranted = await SpeechPermissionRequester.requestSpeechRecognition()

            guard speechGranted else {
                showError("请在设置中允许语音识别权限。")
                return false
            }
        }

        let micGranted = await SpeechPermissionRequester.requestMicrophone()

        guard micGranted else {
            showError("请在设置中允许麦克风权限。")
            return false
        }

        return true
    }

    private func showError(_ message: String) {
        errorMessage = message
        showsError = true
        publishRecordingSnapshot(status: status)
    }

    private func enforceMaximumRecordingDurationIfNeeded() {
        guard isRecording,
              recordingDuration >= SpeechServicePreferences.maximumRecordingDuration else {
            return
        }
        status = "已达到 30 分钟上限，正在保存并进入识别终稿"
        publishRecordingSnapshot(status: status)
        stopRecordingAndTranscribeIfNeeded()
    }
    private func startMetering() {
        meteringTask?.cancel()
        meteringTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refreshMeter()
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
    }

    private func stopMetering() {
        meteringTask?.cancel()
        meteringTask = nil
        refreshMeter()
        audioLevel = 0
        smoothedAudioLevel = 0
        publishRecordingSnapshot(status: status)
    }

    private func refreshMeter() {
        guard let recorder else {
            return
        }

        recorder.updateMeters()
        recordingDuration = recorder.currentTime
        enforceMaximumRecordingDurationIfNeeded()

        let averagePower = Double(recorder.averagePower(forChannel: 0))
        currentDecibels = averagePower

        // AVAudioRecorder reports logarithmic dB values. Lift ordinary speech
        // out of the quiet end of the range, then smooth just enough to avoid
        // flicker while preserving visible syllable-to-syllable movement.
        let linearLevel = max(0, min(1, (averagePower + 55) / 45))
        let perceptualLevel = pow(linearLevel, 0.68)
        smoothedAudioLevel = smoothedAudioLevel * 0.32 + perceptualLevel * 0.68
        audioLevel = smoothedAudioLevel
        peakAudioLevel = max(peakAudioLevel, smoothedAudioLevel)
        publishRecordingSnapshot(status: status)
    }

    private func updateRealtimeMeter(decibels: Double, duration: TimeInterval) {
        guard isRecording || isPreparingRecording else {
            return
        }
        let frameDuration = max(0, duration - lastRealtimeMeterDuration)
        lastRealtimeMeterDuration = duration
        if decibels >= significantAudioThresholdDecibels {
            firstSignificantAudioTime = firstSignificantAudioTime
                ?? max(0, duration - frameDuration)
            lastSignificantAudioTime = duration
            significantAudioDuration += frameDuration
        }
        recordingDuration = duration
        enforceMaximumRecordingDurationIfNeeded()
        currentDecibels = decibels
        let linearLevel = max(0, min(1, (decibels + 55) / 45))
        let perceptualLevel = pow(linearLevel, 0.68)
        smoothedAudioLevel = smoothedAudioLevel * 0.32 + perceptualLevel * 0.68
        audioLevel = smoothedAudioLevel
        peakAudioLevel = max(peakAudioLevel, smoothedAudioLevel)
        publishRecordingSnapshot(status: status)
    }

    private func publishRecordingSnapshot(isTranscribing: Bool? = nil, status: String) {
        SharedCommandStore.updateRecordingSnapshot(
            isPreparing: isPreparingRecording,
            isRecording: isRecording,
            isTranscribing: isTranscribing ?? self.isTranscribing,
            audioLevel: audioLevel,
            decibels: currentDecibels,
            duration: recordingDuration,
            transcript: transcript,
            transcriptIsFinal: realtimeTranscriptIsFinal,
            status: status
        )
    }

    private func updateLastRecordingStats() {
        guard let recordingURL else {
            return
        }

        do {
            let values = try recordingURL.resourceValues(forKeys: [.fileSizeKey])
            lastRecordingFileSize = values.fileSize ?? 0
        } catch {
            lastRecordingFileSize = 0
        }
    }

    private func playLatestRecording() {
        guard let recordingURL else {
            showError("没有可播放的录音。")
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)

            let player = try AVAudioPlayer(contentsOf: recordingURL)
            player.prepareToPlay()
            player.play()

            self.player = player
            isPlaying = true
            status = "正在播放录音"

            playbackStopTask?.cancel()
            let duration = player.duration
            playbackStopTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0.1, duration) * 1_000_000_000))
                guard !Task.isCancelled else {
                    return
                }

                self?.isPlaying = false
                self?.player = nil
                self?.status = "播放完成"
            }
        } catch {
            showError("无法播放录音：\(error.localizedDescription)")
        }
    }

    private func stopPlayback() {
        playbackStopTask?.cancel()
        playbackStopTask = nil
        player?.stop()
        player = nil
        isPlaying = false
    }

}

enum SpeechPermissionRequester {
    static func requestSpeechRecognition() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            break
        @unknown default:
            return false
        }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    static func requestMicrophone() async -> Bool {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                return true
            case .denied:
                return false
            case .undetermined:
                break
            @unknown default:
                return false
            }
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
            case .granted:
                return true
            case .denied:
                return false
            case .undetermined:
                break
            @unknown default:
                return false
            }
        }

        return await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }
}
