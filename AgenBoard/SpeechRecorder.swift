import AVFoundation
import Foundation
import Speech

@MainActor
final class SpeechRecorder: ObservableObject {
    @Published var transcript = ""
    @Published var status = "准备录音"
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
    private var player: AVAudioPlayer?
    private var recordingURL: URL?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var transcriptionTask: Task<Void, Never>?
    private var meteringTask: Task<Void, Never>?
    private var playbackStopTask: Task<Void, Never>?
    private var currentHistoryItemID: UUID?
    private var currentProvider = SpeechRecognitionProvider.apple
    private var currentRecognitionMode = RecognitionHotwordMode.withHotwords
    private var currentLibraryHotwords: [String] = []
    private var currentActiveHotwords: [String] = []
    private var currentConfiguredHotwordCount = 0
    private var legacyTranscriptionStartedAt: Date?
    private var smoothedAudioLevel = 0.0

    init(historyStore: RecognitionHistoryStore) {
        self.historyStore = historyStore
    }

    var buttonTitle: String {
        isRecording ? "停止并识别" : "开始录音"
    }

    var buttonIcon: String {
        isRecording ? "stop.fill" : "mic.fill"
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

    func stopRecordingAndTranscribeIfNeeded() {
        guard isRecording else {
            return
        }

        stopRecordingAndTranscribe()
    }

    func startRecordingIfNeeded(request: SharedRecordingToggleRequest? = nil) {
        guard !isRecording, !isTranscribing else {
            return
        }

        Task {
            await startRecording(request: request)
        }
    }

    func publishCurrentSnapshot() {
        publishRecordingSnapshot(status: status)
    }

    func clear() {
        if isRecording {
            recorder?.stop()
            recorder = nil
            isRecording = false
        }

        stopMetering()
        stopPlayback()
        recognitionTask?.cancel()
        recognitionTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        isTranscribing = false
        transcript = ""
        SharedCommandStore.clearRecognitionResult()
        audioLevel = 0
        smoothedAudioLevel = 0
        peakAudioLevel = 0
        currentDecibels = -80
        recordingDuration = 0
        lastRecordingFileSize = 0
        status = "准备录音"
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
        if currentProvider == .aliyun {
            do {
                _ = try AliyunSpeechConfiguration.load()
            } catch {
                SharedCommandStore.cancelKeyboardAutoInsert()
                showError("阿里云配置不可用：\(error.localizedDescription)")
                return
            }
        }
        guard await requestPermissions(for: currentProvider) else {
            RecordingLaunchMetrics.mark(
                "main_recording_permission_denied",
                request: request
            )
            SharedCommandStore.cancelKeyboardAutoInsert()
            return
        }
        RecordingLaunchMetrics.mark(
            "main_recording_permissions_ready",
            request: request
        )

        recognitionTask?.cancel()
        recognitionTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        currentHistoryItemID = nil
        transcript = ""
        SharedCommandStore.clearRecognitionResult()
        lastRecordingFileSize = 0
        recordingDuration = 0
        audioLevel = 0
        smoothedAudioLevel = 0
        peakAudioLevel = 0
        currentDecibels = -80
        stopPlayback()

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .mixWithOthers])
            try session.setActive(true)
            RecordingLaunchMetrics.mark(
                "main_audio_session_active",
                request: request
            )

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("agenboard-\(UUID().uuidString)")
                .appendingPathExtension("m4a")

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]

            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            recorder.prepareToRecord()

            guard recorder.record() else {
                SharedCommandStore.cancelKeyboardAutoInsert()
                showError("录音启动失败。")
                return
            }

            self.recorder = recorder
            recordingURL = url
            isRecording = true
            status = "正在录音"
            publishRecordingSnapshot(status: status)
            startMetering()
            RecordingLaunchMetrics.mark(
                "main_recorder_started",
                request: request
            )
        } catch {
            RecordingLaunchMetrics.mark(
                "main_recorder_start_failed",
                request: request,
                detail: error.localizedDescription
            )
            SharedCommandStore.cancelKeyboardAutoInsert()
            showError("无法开始录音：\(error.localizedDescription)")
        }
    }

    private func stopRecordingAndTranscribe() {
        recorder?.stop()
        updateLastRecordingStats()
        stopMetering()
        recorder = nil
        isRecording = false
        currentRecognitionMode = RecognitionPreferences.usesHotwords
            ? .withHotwords
            : .withoutHotwords

        if let recordingURL {
            do {
                let archived = try historyStore.archiveRecording(
                    at: recordingURL,
                    duration: recordingDuration,
                    originalMode: currentRecognitionMode,
                    originalProvider: currentProvider
                )
                self.recordingURL = archived.audioURL
                currentHistoryItemID = archived.id
            } catch {
                currentHistoryItemID = nil
                showError("录音历史保存失败，但仍会继续识别：\(error.localizedDescription)")
            }
        }

        status = "录音已停止，正在识别"
        publishRecordingSnapshot(isTranscribing: true, status: status)

        transcriptionTask?.cancel()
        transcriptionTask = Task { [weak self] in
            await self?.transcribeLatestRecording()
            self?.transcriptionTask = nil
        }
    }

    private func transcribeLatestRecording() async {
        guard let recordingURL else {
            SharedCommandStore.cancelKeyboardAutoInsert()
            showError("没有找到录音文件。")
            return
        }

        isTranscribing = true
        let libraryEntries = HotwordLibraryStorage.loadEntries()
        currentLibraryHotwords = libraryEntries.map(\.term)
        currentActiveHotwords = currentRecognitionMode == .withHotwords
            ? HotwordSelectionPolicy.selectedTerms(from: libraryEntries)
            : []
        currentConfiguredHotwordCount = currentActiveHotwords.count

        switch currentRecognitionMode {
        case .withHotwords:
            status = currentActiveHotwords.isEmpty
                ? "正在识别 · 热词词库为空或均已停用"
                : "正在识别 · 已激活 \(currentActiveHotwords.count)/\(HotwordSelectionPolicy.maximumActiveCount) 个热词"
        case .withoutHotwords:
            status = "正在识别 · 不传热词"
        }
        publishRecordingSnapshot(isTranscribing: true, status: status)

        switch currentProvider {
        case .aliyun:
            await transcribeWithAliyun(audioURL: recordingURL)
        case .apple:
            if #available(iOS 26.0, *) {
                await transcribeWithSpeechAnalyzer(audioURL: recordingURL)
            } else {
                transcribeWithLegacyRecognizer(audioURL: recordingURL)
            }
        }
    }

    private func transcribeWithAliyun(audioURL: URL) async {
        do {
            let output = try await AliyunSpeechTranscriber.transcribe(
                audioURL: audioURL,
                hotwords: currentActiveHotwords
            ) { [weak self] progress in
                guard let self else {
                    return
                }
                self.status = progress
                self.publishRecordingSnapshot(isTranscribing: true, status: progress)
            }
            currentConfiguredHotwordCount = output.configuredHotwordCount
            let ignoredSuffix = output.ignoredHotwords.isEmpty
                ? ""
                : "；另有 \(output.ignoredHotwords.count) 个词不符合阿里热词格式限制"
            completeTranscription(
                output.transcript,
                elapsed: output.elapsed,
                provider: .aliyun,
                words: output.words,
                completionNote: ignoredSuffix
            )
        } catch is CancellationError {
            guard !Task.isCancelled else {
                return
            }
            failTranscription("阿里云识别意外中断，请重新录音后再试。")
        } catch {
            failTranscription("阿里云识别失败：\(error.localizedDescription)")
        }
    }

    @available(iOS 26.0, *)
    private func transcribeWithSpeechAnalyzer(audioURL: URL) async {
        do {
            status = "准备中文识别模型"
            publishRecordingSnapshot(isTranscribing: true, status: status)
            let locale = try await AppleSpeechTranscriber.prepareLocale()

            switch currentRecognitionMode {
            case .withHotwords:
                status = currentActiveHotwords.isEmpty
                    ? "正在识别 · 热词词库为空或均已停用"
                    : "正在识别 · 已激活 \(currentActiveHotwords.count)/\(HotwordSelectionPolicy.maximumActiveCount) 个热词"
            case .withoutHotwords:
                status = "正在识别 · 不传热词"
            }
            publishRecordingSnapshot(isTranscribing: true, status: status)
            let output = try await AppleSpeechTranscriber.transcribe(
                audioURL: audioURL,
                locale: locale,
                hotwords: currentActiveHotwords
            )
            completeTranscription(
                output.transcript,
                elapsed: output.elapsed,
                provider: .apple,
                words: []
            )
        } catch is CancellationError {
            guard !Task.isCancelled else {
                return
            }
            failTranscription("SpeechAnalyzer 意外中断，请重新录音后再试。")
        } catch {
            failTranscription("识别失败：\(error.localizedDescription)")
        }
    }

    private func transcribeWithLegacyRecognizer(audioURL: URL) {
        guard let recognizer else {
            failTranscription("当前设备不支持中文语音识别。")
            return
        }

        guard recognizer.isAvailable else {
            failTranscription("Apple Speech 当前不可用，请稍后再试。")
            return
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.contextualStrings = HotwordSelectionPolicy.limitedTerms(currentActiveHotwords)
        legacyTranscriptionStartedAt = Date()

        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else {
                    return
                }

                if let result {
                    self.transcript = SpeechTranscriptNormalizer.normalize(
                        result.bestTranscription.formattedString
                    )
                }

                if let error {
                    self.recognitionTask = nil
                    self.failTranscription("识别失败：\(error.localizedDescription)")
                    return
                }

                if result?.isFinal == true {
                    self.recognitionTask = nil
                    let elapsed = Date().timeIntervalSince(
                        self.legacyTranscriptionStartedAt ?? Date()
                    )
                    self.completeTranscription(
                        self.transcript,
                        elapsed: elapsed,
                        provider: .apple,
                        words: []
                    )
                }
            }
        }
    }

    private func completeTranscription(
        _ text: String,
        elapsed: TimeInterval,
        provider: SpeechRecognitionProvider,
        words: [SpeechRecognitionWord],
        completionNote: String = ""
    ) {
        transcript = SpeechTranscriptNormalizer.normalize(text)
        isTranscribing = false
        let matchedTerms = HotwordTranscriptMatcher.matches(
            in: transcript,
            hotwords: currentLibraryHotwords
        )
        HotwordLibraryStorage.markTermsUsed(matchedTerms)

        if let currentHistoryItemID {
            do {
                try historyStore.storeTranscription(
                    itemID: currentHistoryItemID,
                    mode: currentRecognitionMode,
                    transcript: transcript,
                    elapsed: elapsed,
                    configuredHotwordCount: currentConfiguredHotwordCount,
                    matchedTerms: matchedTerms,
                    provider: provider,
                    words: words
                )
            } catch {
                showError("识别已完成，但历史转写保存失败：\(error.localizedDescription)")
            }
        }

        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            status = "未识别到文字"
            SharedCommandStore.cancelKeyboardAutoInsert()
        } else {
            status = "识别完成 · \(provider.shortTitle)\(completionNote)"
            SharedCommandStore.publishRecognitionResult(transcript)
        }
        publishRecordingSnapshot(status: status)
    }

    private func failTranscription(_ message: String) {
        isTranscribing = false
        status = "识别失败"
        if let currentHistoryItemID {
            historyStore.storeFailure(
                itemID: currentHistoryItemID,
                mode: currentRecognitionMode,
                provider: currentProvider,
                message: message
            )
        }
        SharedCommandStore.cancelKeyboardAutoInsert()
        publishRecordingSnapshot(status: status)
        showError(message)
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

    private func publishRecordingSnapshot(isTranscribing: Bool? = nil, status: String) {
        SharedCommandStore.updateRecordingSnapshot(
            isRecording: isRecording,
            isTranscribing: isTranscribing ?? self.isTranscribing,
            audioLevel: audioLevel,
            decibels: currentDecibels,
            duration: recordingDuration,
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

enum SpeechTranscriptNormalizer {
    static func normalize(_ text: String) -> String {
        var output = text
        let replacements: [(String, String)] = [
            ("斜杠 new", "/new"),
            ("斜杠new", "/new"),
            ("slash new", "/new"),
            ("斜杠 start", "/start"),
            ("斜杠start", "/start"),
            ("slash start", "/start"),
            ("open claw", "OpenClaw"),
            ("克劳德 code", "Claude Code")
        ]

        for (pattern, replacement) in replacements {
            output = output.replacingOccurrences(of: pattern, with: replacement, options: [.caseInsensitive])
        }

        return output
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
