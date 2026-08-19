@preconcurrency import AVFoundation
import Foundation

struct RealtimeRecognitionMetrics: Codable, Equatable, Sendable {
    let connectionElapsed: TimeInterval
    let firstResultElapsed: TimeInterval?
    let finalizationElapsed: TimeInterval
    let billedDurationSeconds: Int?
}

struct VolcRealtimeRecognitionOutput: Sendable {
    let serviceOutput: SpeechRecognitionServiceOutput
    let metrics: RealtimeRecognitionMetrics
}

private struct VolcHotwordSetup: Sendable {
    let acceptedTerms: [String]
    let ignoredTerms: [String]

    static func prepare(_ hotwords: [String]) -> VolcHotwordSetup {
        let plan = HotwordSelectionPolicy.plan(
            from: hotwords,
            provider: .volcRealtime
        )
        return VolcHotwordSetup(
            acceptedTerms: plan.acceptedTerms,
            ignoredTerms: plan.exclusions.map(\.term)
        )
    }
}

@MainActor
enum VolcRealtimeSpeechTranscriber {
    typealias ProgressHandler = @MainActor @Sendable (String) -> Void

    static func transcribe(
        audioURL: URL,
        hotwords: [String],
        playbackRate: Double = 1,
        launchRequest: SharedRecordingToggleRequest? = nil,
        progress: @escaping ProgressHandler
    ) async throws -> VolcRealtimeRecognitionOutput {
        let session = VolcRealtimeSpeechSession(
            configuration: try VolcSpeechConfiguration.load(),
            hotwords: hotwords,
            transcriptionMode: SpeechServicePreferences.volcRealtimeTranscriptionMode,
            launchRequest: launchRequest
        ) { text, isFinal in
            let characterCount = text.count
            progress(
                isFinal
                    ? "豆包实时 · 已生成确定句 · \(characterCount) 字"
                    : "豆包实时 · 转写中 · \(characterCount) 字"
            )
        }

        do {
            progress("豆包实时 · 正在建立连接")
            try await session.connect()
            progress(
                playbackRate > 1
                    ? String(
                        format: "豆包实时 · 正在以 %.1f 倍速恢复缓存",
                        min(1.5, playbackRate)
                    )
                    : "豆包实时 · 正在按录音原速推流"
            )
            try await streamAudioFile(
                audioURL,
                to: session,
                playbackRate: playbackRate
            )
            progress("豆包实时 · 正在等待二遍终稿")
            return try await session.finish()
        } catch {
            session.cancel()
            throw error
        }
    }

    static func validateConfiguration() async throws {
        let session = VolcRealtimeSpeechSession(
            configuration: try VolcSpeechConfiguration.load(),
            hotwords: [],
            transcriptionMode: .naturalDictation
        ) { _, _ in }
        do {
            try await session.connect()
            session.cancel()
        } catch {
            session.cancel()
            throw error
        }
    }

    private static func streamAudioFile(
        _ audioURL: URL,
        to session: VolcRealtimeSpeechSession,
        playbackRate: Double
    ) async throws {
        let asset = AVURLAsset(url: audioURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw VolcSpeechServiceError.configuration("历史录音中没有可识别的音轨。")
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw VolcSpeechServiceError.configuration("无法读取历史录音的 PCM 音频。")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error
                ?? VolcSpeechServiceError.configuration("无法开始读取历史录音。")
        }
        defer {
            if reader.status == .reading {
                reader.cancelReading()
            }
        }

        let bytesPerSecond = 16_000 * MemoryLayout<Int16>.size
        let packetByteCount = bytesPerSecond / 10
        let streamStartedAt = Date()
        var pending = Data()
        var sentByteCount = 0

        while reader.status == .reading {
            try Task.checkCancellation()
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                break
            }
            if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                let length = CMBlockBufferGetDataLength(blockBuffer)
                var bytes = [UInt8](repeating: 0, count: length)
                let status = bytes.withUnsafeMutableBytes { destination in
                    CMBlockBufferCopyDataBytes(
                        blockBuffer,
                        atOffset: 0,
                        dataLength: length,
                        destination: destination.baseAddress!
                    )
                }
                guard status == kCMBlockBufferNoErr else {
                    throw VolcSpeechServiceError.invalidResponse(
                        "读取历史录音 PCM 数据失败（\(status)）。"
                    )
                }
                pending.append(contentsOf: bytes)
            }

            while pending.count >= packetByteCount {
                let packet = Data(pending.prefix(packetByteCount))
                pending.removeFirst(packetByteCount)
                try await session.sendAudio(packet)
                sentByteCount += packet.count
                try await paceAudio(
                    sentByteCount: sentByteCount,
                    bytesPerSecond: bytesPerSecond,
                    playbackRate: playbackRate,
                    startedAt: streamStartedAt
                )
            }
        }

        if reader.status == .failed {
            throw reader.error
                ?? VolcSpeechServiceError.invalidResponse("读取历史录音失败。")
        }
        if !pending.isEmpty {
            pending.append(Data(count: packetByteCount - pending.count))
            try await session.sendAudio(pending)
            sentByteCount += pending.count
            try await paceAudio(
                sentByteCount: sentByteCount,
                bytesPerSecond: bytesPerSecond,
                playbackRate: playbackRate,
                startedAt: streamStartedAt
            )
        }
    }

    private static func paceAudio(
        sentByteCount: Int,
        bytesPerSecond: Int,
        playbackRate: Double,
        startedAt: Date
    ) async throws {
        let safePlaybackRate = max(1, min(1.5, playbackRate))
        let targetElapsed = Double(sentByteCount)
            / Double(bytesPerSecond)
            / safePlaybackRate
        let delay = targetElapsed - Date().timeIntervalSince(startedAt)
        guard delay > 0 else {
            return
        }
        try await Task.sleep(
            nanoseconds: UInt64(delay * 1_000_000_000)
        )
    }
}

@MainActor
final class VolcRealtimeSpeechSession {
    typealias TranscriptHandler = @MainActor @Sendable (String, Bool) -> Void

    private let configuration: VolcSpeechConfiguration
    private let hotwordSetup: VolcHotwordSetup
    private let transcriptionMode: VolcRealtimeTranscriptionMode
    private let launchRequest: SharedRecordingToggleRequest?
    private let transcriptHandler: TranscriptHandler

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var startWaiter: CheckedContinuation<Void, Error>?
    private var finishWaiter: CheckedContinuation<Void, Error>?
    private var startTimeoutTask: Task<Void, Never>?
    private var finishTimeoutTask: Task<Void, Never>?
    private var resultStabilityTask: Task<Void, Never>?
    private var didStart = false
    private var didRequestFinish = false
    private var didFinish = false
    private var terminalError: Error?
    private var decoder = VolcSaucDecoder()
    private var lastTranscript = ""
    private var lastWords: [SpeechRecognitionWord] = []
    private var connectionStartedAt: Date?
    private var connectionReadyAt: Date?
    private var firstAudioSentAt: Date?
    private var firstResultAt: Date?
    private var finalizationStartedAt: Date?
    private var sentAudioBytes = 0
    private var responseCount = 0

    init(
        configuration: VolcSpeechConfiguration,
        hotwords: [String],
        transcriptionMode: VolcRealtimeTranscriptionMode,
        launchRequest: SharedRecordingToggleRequest? = nil,
        transcriptHandler: @escaping TranscriptHandler
    ) {
        self.configuration = configuration
        hotwordSetup = VolcHotwordSetup.prepare(hotwords)
        self.transcriptionMode = transcriptionMode
        self.launchRequest = launchRequest
        self.transcriptHandler = transcriptHandler
    }

    func connect() async throws {
        try Task.checkCancellation()
        connectionStartedAt = Date()

        var request = URLRequest(url: VolcSpeechConfiguration.realtimeWebSocketURL)
        request.setValue(configuration.apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(configuration.resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Api-Connect-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        request.setValue("AgenBoard-iOS/0.1", forHTTPHeaderField: "User-Agent")

        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        startReceiving(from: socket)
        try await socket.send(.data(try startFrame()))
        try await waitUntilStarted()
    }

    func sendAudio(_ data: Data) async throws {
        try Task.checkCancellation()
        guard didStart, !didRequestFinish, !didFinish, let socket else {
            if let terminalError {
                throw terminalError
            }
            throw VolcSpeechServiceError.taskFailed("豆包实时识别连接尚未就绪。")
        }
        if firstAudioSentAt == nil, !data.isEmpty {
            firstAudioSentAt = Date()
        }
        try await socket.send(
            .data(
                volcFrame(
                    messageType: 0b0010,
                    flags: 0b0000,
                    serialization: 0b0000,
                    payload: data
                )
            )
        )
        sentAudioBytes += data.count
    }

    func finish() async throws -> VolcRealtimeRecognitionOutput {
        try Task.checkCancellation()
        guard let socket else {
            throw VolcSpeechServiceError.taskFailed("豆包实时识别连接不存在。")
        }
        if let terminalError {
            throw terminalError
        }
        guard !didRequestFinish else {
            throw VolcSpeechServiceError.taskFailed("豆包实时识别已经进入收尾阶段。")
        }

        didRequestFinish = true
        finalizationStartedAt = Date()
        try await socket.send(
            .data(
                volcFrame(
                    messageType: 0b0010,
                    flags: 0b0010,
                    serialization: 0b0000,
                    payload: Data()
                )
            )
        )
        try await waitUntilFinished()

        let now = Date()
        let connectionElapsed = connectionReadyAt?.timeIntervalSince(
            connectionStartedAt ?? connectionReadyAt ?? now
        ) ?? 0
        let firstResultElapsed = firstResultAt.flatMap { firstResultAt in
            firstAudioSentAt.map { firstResultAt.timeIntervalSince($0) }
        }
        let finalizationElapsed = now.timeIntervalSince(finalizationStartedAt ?? now)

        RecordingLaunchMetrics.mark(
            "main_realtime_session_finished",
            request: launchRequest,
            detail: [
                "engine=volc_seedasr_2",
                "audio_bytes=\(sentAudioBytes)",
                "responses=\(responseCount)",
                "mode=\(transcriptionMode.rawValue)",
                "transcript_chars=\(lastTranscript.count)"
            ].joined(separator: " ")
        )
        closeSocket()
        return VolcRealtimeRecognitionOutput(
            serviceOutput: SpeechRecognitionServiceOutput(
                transcript: lastTranscript,
                elapsed: finalizationElapsed,
                words: lastWords,
                configuredHotwordCount: hotwordSetup.acceptedTerms.count,
                ignoredHotwords: hotwordSetup.ignoredTerms
            ),
            metrics: RealtimeRecognitionMetrics(
                connectionElapsed: connectionElapsed,
                firstResultElapsed: firstResultElapsed,
                finalizationElapsed: finalizationElapsed,
                billedDurationSeconds: nil
            )
        )
    }

    func cancel() {
        fail(CancellationError())
        closeSocket()
    }

    private func startReceiving(from socket: URLSessionWebSocketTask) {
        receiveTask?.cancel()
        receiveTask = Task { @MainActor [weak self, weak socket] in
            guard let self, let socket else {
                return
            }
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    switch message {
                    case .data(let data):
                        try self.handleServerData(data)
                    case .string(let value):
                        try self.handleServerData(Data(value.utf8))
                    @unknown default:
                        break
                    }
                    if self.didFinish || self.terminalError != nil {
                        return
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                if self.didRequestFinish, self.terminalError == nil {
                    self.completeFinish()
                } else {
                    self.fail(
                        VolcSpeechServiceError.taskFailed(
                            "火山引擎连接中断：\(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    private func handleServerData(_ data: Data) throws {
        decoder.append(data)
        for frame in try decoder.takeFrames() {
            switch frame {
            case .response(let payload, let isFinal):
                if !didStart {
                    didStart = true
                    connectionReadyAt = Date()
                    startTimeoutTask?.cancel()
                    startTimeoutTask = nil
                    startWaiter?.resume()
                    startWaiter = nil
                }
                try handleResponsePayload(payload, isFinal: isFinal)
            case .error(let code, let message):
                fail(
                    VolcSpeechServiceError.taskFailed(
                        "火山引擎实时识别失败（\(code)）：\(message)"
                    )
                )
            case .ignored:
                break
            }
        }
    }

    private func handleResponsePayload(_ data: Data, isFinal: Bool) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw VolcSpeechServiceError.invalidResponse(
                "解析火山引擎响应失败：\(error.localizedDescription)"
            )
        }
        guard let envelope = object as? [String: Any] else {
            throw VolcSpeechServiceError.invalidResponse("火山引擎响应不是有效的 JSON 对象。")
        }

        responseCount += 1
        let result = envelope["result"] as? [String: Any]
        let text = (result?["text"] as? String) ?? ""
        let utterances = result?["utterances"] as? [[String: Any]] ?? []
        let hasDefinite = utterances.contains { utterance in
            (utterance["definite"] as? Bool) == true
                && !((utterance["text"] as? String) ?? "").isEmpty
        }

        if !text.isEmpty {
            lastTranscript = text
            if firstResultAt == nil {
                firstResultAt = Date()
            }
        }
        let parsedWords = parseWords(from: utterances)
        if !parsedWords.isEmpty {
            lastWords = parsedWords
        }
        if !lastTranscript.isEmpty {
            transcriptHandler(lastTranscript, hasDefinite)
        }

        guard didRequestFinish else {
            return
        }
        if isFinal {
            completeFinish()
            return
        }

        resultStabilityTask?.cancel()
        let idleNanoseconds: UInt64 = hasDefinite
            ? 800_000_000
            : 2_500_000_000
        resultStabilityTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: idleNanoseconds)
            guard !Task.isCancelled else {
                return
            }
            self?.completeFinish()
        }
    }

    private func parseWords(
        from utterances: [[String: Any]]
    ) -> [SpeechRecognitionWord] {
        utterances.flatMap { utterance in
            let words = utterance["words"] as? [[String: Any]] ?? []
            return words.compactMap { word -> SpeechRecognitionWord? in
                let text = (word["text"] as? String)
                    ?? (word["word"] as? String)
                    ?? ""
                guard !text.isEmpty else {
                    return nil
                }
                let begin = integerValue(
                    word["start_time"]
                        ?? word["begin_time"]
                        ?? word["startTime"]
                )
                let end = integerValue(
                    word["end_time"]
                        ?? word["endTime"]
                )
                return SpeechRecognitionWord(
                    text: text,
                    beginTimeMilliseconds: begin,
                    endTimeMilliseconds: max(begin, end),
                    punctuation: word["punctuation"] as? String
                )
            }
        }
    }

    private func integerValue(_ value: Any?) -> Int {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value) ?? 0
        }
        return 0
    }

    private func waitUntilStarted() async throws {
        if didStart {
            return
        }
        if let terminalError {
            throw terminalError
        }
        startTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, let self, !self.didStart else {
                return
            }
            self.fail(VolcSpeechServiceError.timeout("火山引擎实时识别连接超时。"))
        }
        try await withCheckedThrowingContinuation { continuation in
            startWaiter = continuation
        }
    }

    private func waitUntilFinished() async throws {
        if didFinish {
            return
        }
        if let terminalError {
            throw terminalError
        }
        finishTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled, let self, !self.didFinish else {
                return
            }
            self.completeFinish()
        }
        try await withCheckedThrowingContinuation { continuation in
            finishWaiter = continuation
        }
    }

    private func completeFinish() {
        guard !didFinish, terminalError == nil else {
            return
        }
        didFinish = true
        finishTimeoutTask?.cancel()
        resultStabilityTask?.cancel()
        finishTimeoutTask = nil
        resultStabilityTask = nil
        finishWaiter?.resume()
        finishWaiter = nil
    }

    private func fail(_ error: Error) {
        guard terminalError == nil, !didFinish else {
            return
        }
        terminalError = error
        startTimeoutTask?.cancel()
        finishTimeoutTask?.cancel()
        resultStabilityTask?.cancel()
        startWaiter?.resume(throwing: error)
        finishWaiter?.resume(throwing: error)
        startWaiter = nil
        finishWaiter = nil
    }

    private func closeSocket() {
        startTimeoutTask?.cancel()
        finishTimeoutTask?.cancel()
        resultStabilityTask?.cancel()
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }

    private func startFrame() throws -> Data {
        var request: [String: Any] = [
            "model_name": "bigmodel",
            "enable_nonstream": true,
            "enable_itn": true,
            "enable_punc": transcriptionMode.semanticPunctuationEnabled,
            "enable_ddc": false,
            "ssd_version": "200",
            "show_utterances": true,
            "result_type": "full"
        ]
        if let silence = transcriptionMode.maxSentenceSilenceMilliseconds {
            request["end_window_size"] = max(200, silence)
            request["force_to_speech_time"] = 1_000
        }
        if !hotwordSetup.acceptedTerms.isEmpty {
            let context: [String: Any] = [
                "hotwords": hotwordSetup.acceptedTerms.map { ["word": $0] }
            ]
            let contextData = try JSONSerialization.data(withJSONObject: context)
            request["corpus"] = [
                "context": String(decoding: contextData, as: UTF8.self)
            ]
        }

        let payload: [String: Any] = [
            "user": [
                "uid": "agenboard-ios",
                "did": "agenboard",
                "platform": "iOS",
                "sdk_version": "0.1",
                "app_version": "0.1.0"
            ],
            "audio": [
                "format": "pcm",
                "codec": "raw",
                "rate": 16_000,
                "bits": 16,
                "channel": 1
            ],
            "request": request
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return volcFrame(
            messageType: 0b0001,
            flags: 0b0000,
            serialization: 0b0001,
            payload: data
        )
    }
}

private enum VolcSaucServerFrame {
    case response(payload: Data, isFinal: Bool)
    case error(code: UInt32, message: String)
    case ignored
}

private struct VolcSaucDecoder {
    private var buffer = Data()

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    mutating func takeFrames() throws -> [VolcSaucServerFrame] {
        var frames: [VolcSaucServerFrame] = []
        while let frame = try takeFrame() {
            frames.append(frame)
        }
        return frames
    }

    private mutating func takeFrame() throws -> VolcSaucServerFrame? {
        guard buffer.count >= 4 else {
            return nil
        }
        let messageType = buffer[buffer.startIndex + 1] >> 4
        let flags = buffer[buffer.startIndex + 1] & 0x0f
        let compression = buffer[buffer.startIndex + 2] & 0x0f
        guard compression == 0 else {
            throw VolcSpeechServiceError.invalidResponse(
                "火山引擎响应使用了不支持的压缩方式（\(compression)）。"
            )
        }

        var offset = 4
        if (1...3).contains(flags) {
            guard buffer.count >= offset + 4 else {
                return nil
            }
            offset += 4
        }
        guard buffer.count >= offset + 4 else {
            return nil
        }
        let payloadSize = Int(readUInt32(buffer, at: offset))
        offset += 4
        guard buffer.count >= offset + payloadSize else {
            return nil
        }
        let payloadStart = buffer.index(buffer.startIndex, offsetBy: offset)
        let payloadEnd = buffer.index(payloadStart, offsetBy: payloadSize)
        let payload = Data(buffer[payloadStart..<payloadEnd])
        buffer.removeFirst(offset + payloadSize)

        switch messageType {
        case 0b1001:
            return .response(
                payload: payload,
                isFinal: flags == 0b0010 || flags == 0b0011
            )
        case 0b1111:
            let error = parseVolcError(payload)
            return .error(code: error.code, message: error.message)
        default:
            return .ignored
        }
    }
}

private func volcFrame(
    messageType: UInt8,
    flags: UInt8,
    serialization: UInt8,
    payload: Data
) -> Data {
    var frame = Data([
        0b0001_0001,
        (messageType << 4) | flags,
        serialization << 4,
        0
    ])
    appendUInt32(UInt32(payload.count), to: &frame)
    frame.append(payload)
    return frame
}

private func appendUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
}

private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
    let start = data.index(data.startIndex, offsetBy: offset)
    let end = data.index(start, offsetBy: 4)
    let bytes = data[start..<end]
    return bytes.reduce(UInt32(0)) { partial, byte in
        (partial << 8) | UInt32(byte)
    }
}

private func parseVolcError(_ payload: Data) -> (code: UInt32, message: String) {
    if payload.count >= 8 {
        let code = readUInt32(payload, at: 0)
        let messageSize = Int(readUInt32(payload, at: 4))
        if payload.count >= 8 + messageSize {
            let messageStart = payload.index(payload.startIndex, offsetBy: 8)
            let messageEnd = payload.index(messageStart, offsetBy: messageSize)
            let messageData = Data(payload[messageStart..<messageEnd])
            let raw = String(data: messageData, encoding: .utf8) ?? "未知错误"
            if let object = try? JSONSerialization.jsonObject(with: messageData),
               let json = object as? [String: Any] {
                let message = (json["message"] as? String)
                    ?? (json["error"] as? String)
                    ?? raw
                return (code, message)
            }
            return (code, raw)
        }
    }
    if let object = try? JSONSerialization.jsonObject(with: payload),
       let json = object as? [String: Any] {
        let code = (json["code"] as? NSNumber)?.uint32Value ?? 0
        let message = (json["message"] as? String)
            ?? (json["error"] as? String)
            ?? "火山引擎返回未知错误"
        return (code, message)
    }
    return (0, String(data: payload, encoding: .utf8) ?? "未知错误")
}

final class RealtimeAudioCapture: @unchecked Sendable {
    typealias MeterHandler = @MainActor @Sendable (Double, TimeInterval) -> Void
    typealias AudioBufferHandler = (AVAudioPCMBuffer) -> Void

    private let engine = AVAudioEngine()
    private let audioContinuation: AsyncStream<Data>.Continuation?
    private let audioBufferHandler: AudioBufferHandler?
    private let meterHandler: MeterHandler
    private let stateLock = NSLock()
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var totalOutputFrames: AVAudioFramePosition = 0
    private var isStopped = false

    var capturedPCMByteCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Int(totalOutputFrames) * MemoryLayout<Int16>.size
    }

    init(
        fileURL: URL,
        audioContinuation: AsyncStream<Data>.Continuation? = nil,
        audioBufferHandler: AudioBufferHandler? = nil,
        meterHandler: @escaping MeterHandler
    ) throws {
        self.audioContinuation = audioContinuation
        self.audioBufferHandler = audioBufferHandler
        self.meterHandler = meterHandler

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let audioFile = try AVAudioFile(
            forWriting: fileURL,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0,
              let converter = AVAudioConverter(
                  from: inputFormat,
                  to: audioFile.processingFormat
              ) else {
            throw VolcSpeechServiceError.configuration("无法准备实时录音音频转换器。")
        }

        self.audioFile = audioFile
        self.converter = converter
        outputFormat = audioFile.processingFormat

        input.installTap(
            onBus: 0,
            bufferSize: 4_096,
            format: inputFormat
        ) { [weak self] buffer, _ in
            self?.process(buffer)
        }
    }

    func start() throws {
        engine.prepare()
        try engine.start()
    }

    func stop() {
        stateLock.lock()
        guard !isStopped else {
            stateLock.unlock()
            return
        }
        isStopped = true
        stateLock.unlock()

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        stateLock.lock()
        audioFile = nil
        converter = nil
        outputFormat = nil
        stateLock.unlock()
        audioContinuation?.finish()
    }

    private func process(_ inputBuffer: AVAudioPCMBuffer) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isStopped,
              let audioFile,
              let converter,
              let outputFormat else {
            return
        }

        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(
            ceil(Double(inputBuffer.frameLength) * ratio)
        ) + 32
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else {
            return
        }

        let inputState = RealtimeAudioConverterInputState(buffer: inputBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) {
            _, outputStatus in
            guard !inputState.didSupply else {
                outputStatus.pointee = .noDataNow
                return nil
            }
            inputState.didSupply = true
            outputStatus.pointee = .haveData
            return inputState.buffer
        }
        guard status != .error,
              conversionError == nil,
              outputBuffer.frameLength > 0 else {
            return
        }

        do {
            try audioFile.write(from: outputBuffer)
        } catch {
            return
        }

        let frameLength = Int(outputBuffer.frameLength)
        guard let samples = outputBuffer.floatChannelData?[0] else {
            return
        }
        var pcm = [Int16](repeating: 0, count: frameLength)
        var squareSum = 0.0
        for index in 0..<frameLength {
            let sample = max(-1, min(1, samples[index]))
            squareSum += Double(sample * sample)
            pcm[index] = Int16((sample * Float(Int16.max)).rounded()).littleEndian
        }

        totalOutputFrames += AVAudioFramePosition(frameLength)
        let duration = Double(totalOutputFrames) / outputFormat.sampleRate
        let rms = sqrt(squareSum / Double(max(1, frameLength)))
        let decibels = max(-80, 20 * log10(max(rms, 0.000_1)))
        audioContinuation?.yield(pcm.withUnsafeBytes { Data($0) })
        audioBufferHandler?(outputBuffer)
        Task { @MainActor [meterHandler] in
            meterHandler(decibels, duration)
        }
    }
}

private final class RealtimeAudioConverterInputState: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var didSupply = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}
