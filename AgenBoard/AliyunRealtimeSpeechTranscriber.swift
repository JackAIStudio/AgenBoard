@preconcurrency import AVFoundation
import Foundation

struct AliyunRealtimeRecognitionMetrics: Codable, Equatable, Sendable {
    let connectionElapsed: TimeInterval
    let firstResultElapsed: TimeInterval?
    let finalizationElapsed: TimeInterval
    let billedDurationSeconds: Int?
}

struct AliyunRealtimeRecognitionOutput: Sendable {
    let serviceOutput: SpeechRecognitionServiceOutput
    let metrics: AliyunRealtimeRecognitionMetrics
}

@MainActor
enum AliyunRealtimeSpeechTranscriber {
    typealias ProgressHandler = @MainActor @Sendable (String) -> Void

    /// 将历史录音按真实时间节奏送入流式接口，便于使用完全相同的音频
    /// 对照文件版与实时版的识别准确率、热词命中和收尾延迟。
    static func transcribe(
        audioURL: URL,
        hotwords: [String],
        progress: @escaping ProgressHandler
    ) async throws -> AliyunRealtimeRecognitionOutput {
        progress("阿里实时 · 正在同步热词")
        let vocabulary = try await AliyunSpeechTranscriber.prepareVocabulary(
            hotwords: hotwords,
            target: .realtime
        )
        let session = AliyunRealtimeSpeechSession(
            configuration: try AliyunSpeechConfiguration.load(),
            vocabulary: vocabulary
        ) { text, isFinal in
            let characterCount = text.count
            progress(
                isFinal
                    ? "阿里实时 · 已生成句子 · \(characterCount) 字"
                    : "阿里实时 · 转写中 · \(characterCount) 字"
            )
        }

        do {
            progress("阿里实时 · 正在建立连接")
            try await session.connect()
            progress("阿里实时 · 正在按录音原速推流")
            try await streamAudioFile(audioURL, to: session)
            progress("阿里实时 · 正在等待最终结果")
            return try await session.finish()
        } catch {
            session.cancel()
            throw error
        }
    }

    private static func streamAudioFile(
        _ audioURL: URL,
        to session: AliyunRealtimeSpeechSession
    ) async throws {
        let asset = AVURLAsset(url: audioURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw AliyunSpeechServiceError.configuration("历史录音中没有可识别的音轨。")
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
            throw AliyunSpeechServiceError.configuration("无法读取历史录音的 PCM 音频。")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error
                ?? AliyunSpeechServiceError.configuration("无法开始读取历史录音。")
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
                    throw AliyunSpeechServiceError.invalidResponse(
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
                    startedAt: streamStartedAt
                )
            }
        }

        if reader.status == .failed {
            throw reader.error
                ?? AliyunSpeechServiceError.invalidResponse("读取历史录音失败。")
        }
        if !pending.isEmpty {
            try await session.sendAudio(pending)
            sentByteCount += pending.count
            try await paceAudio(
                sentByteCount: sentByteCount,
                bytesPerSecond: bytesPerSecond,
                startedAt: streamStartedAt
            )
        }
    }

    private static func paceAudio(
        sentByteCount: Int,
        bytesPerSecond: Int,
        startedAt: Date
    ) async throws {
        let targetElapsed = Double(sentByteCount) / Double(bytesPerSecond)
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
final class AliyunRealtimeSpeechSession {
    typealias TranscriptHandler = @MainActor @Sendable (String, Bool) -> Void

    private let configuration: AliyunSpeechConfiguration
    private let vocabulary: AliyunVocabularySetup
    private let transcriptHandler: TranscriptHandler
    private let taskID = UUID().uuidString.lowercased()

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var startWaiter: CheckedContinuation<Void, Error>?
    private var finishWaiter: CheckedContinuation<Void, Error>?
    private var startTimeoutTask: Task<Void, Never>?
    private var finishTimeoutTask: Task<Void, Never>?
    private var didStart = false
    private var didFinish = false
    private var terminalError: Error?
    private var finalSentences: [Int: RealtimeSentence] = [:]
    private var interimSentence: RealtimeSentence?
    private var connectionStartedAt: Date?
    private var taskStartedAt: Date?
    private var firstAudioSentAt: Date?
    private var firstResultAt: Date?
    private var finishSentAt: Date?
    private var billedDurationSeconds: Int?

    init(
        configuration: AliyunSpeechConfiguration,
        vocabulary: AliyunVocabularySetup,
        transcriptHandler: @escaping TranscriptHandler
    ) {
        self.configuration = configuration
        self.vocabulary = vocabulary
        self.transcriptHandler = transcriptHandler
    }

    func connect() async throws {
        try Task.checkCancellation()
        connectionStartedAt = Date()

        var request = URLRequest(url: AliyunSpeechConfiguration.realtimeWebSocketURL)
        request.setValue(
            "Bearer \(configuration.apiKey)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("AgenBoard-iOS/0.1", forHTTPHeaderField: "User-Agent")

        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        startReceiving(from: socket)

        try await socket.send(.string(try runTaskMessage()))
        try await waitUntilStarted()
    }

    func sendAudio(_ data: Data) async throws {
        try Task.checkCancellation()
        guard didStart, !didFinish, terminalError == nil, let socket else {
            if let terminalError {
                throw terminalError
            }
            throw AliyunSpeechServiceError.taskFailed("阿里云实时识别连接尚未就绪。")
        }
        if firstAudioSentAt == nil, !data.isEmpty {
            firstAudioSentAt = Date()
        }
        try await socket.send(.data(data))
    }

    func finish() async throws -> AliyunRealtimeRecognitionOutput {
        try Task.checkCancellation()
        guard let socket else {
            throw AliyunSpeechServiceError.taskFailed("阿里云实时识别连接不存在。")
        }
        if let terminalError {
            throw terminalError
        }

        finishSentAt = Date()
        try await socket.send(.string(try finishTaskMessage()))
        try await waitUntilFinished()

        let sentences = finalSentences.values.sorted { lhs, rhs in
            lhs.sentenceID < rhs.sentenceID
        }
        let transcript = sentences.map(\.text).joined()
        let words = sentences.flatMap { sentence in
            (sentence.words ?? []).map { word in
                SpeechRecognitionWord(
                    text: word.text,
                    beginTimeMilliseconds: word.beginTime,
                    endTimeMilliseconds: word.endTime,
                    punctuation: word.punctuation
                )
            }
        }
        let now = Date()
        let connectionElapsed = taskStartedAt?.timeIntervalSince(
            connectionStartedAt ?? taskStartedAt ?? now
        ) ?? 0
        let firstResultElapsed = firstResultAt.flatMap { firstResultAt in
            firstAudioSentAt.map { firstResultAt.timeIntervalSince($0) }
        }
        let finalizationElapsed = now.timeIntervalSince(finishSentAt ?? now)

        closeSocket()
        return AliyunRealtimeRecognitionOutput(
            serviceOutput: SpeechRecognitionServiceOutput(
                transcript: transcript,
                elapsed: finalizationElapsed,
                words: words,
                configuredHotwordCount: vocabulary.acceptedTerms.count,
                ignoredHotwords: vocabulary.ignoredTerms
            ),
            metrics: AliyunRealtimeRecognitionMetrics(
                connectionElapsed: connectionElapsed,
                firstResultElapsed: firstResultElapsed,
                finalizationElapsed: finalizationElapsed,
                billedDurationSeconds: billedDurationSeconds
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
                    case .string(let value):
                        try self.handleServerMessage(Data(value.utf8))
                    case .data(let data):
                        try self.handleServerMessage(data)
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
                self.fail(error)
            }
        }
    }

    private func handleServerMessage(_ data: Data) throws {
        let message: RealtimeServerEnvelope
        do {
            message = try JSONDecoder().decode(RealtimeServerEnvelope.self, from: data)
        } catch {
            throw AliyunSpeechServiceError.invalidResponse(
                "阿里云实时识别响应无法解析：\(decodingErrorDescription(error))"
            )
        }

        switch message.header.event {
        case "task-started":
            didStart = true
            taskStartedAt = Date()
            startTimeoutTask?.cancel()
            startTimeoutTask = nil
            startWaiter?.resume()
            startWaiter = nil

        case "result-generated":
            guard let sentence = message.payload?.output?.sentence,
                  !sentence.heartbeat else {
                return
            }
            if firstResultAt == nil {
                firstResultAt = Date()
            }
            if let duration = message.payload?.usage?.duration {
                billedDurationSeconds = max(billedDurationSeconds ?? 0, duration)
            }
            if sentence.sentenceEnd {
                finalSentences[sentence.sentenceID] = sentence
                interimSentence = nil
            } else {
                interimSentence = sentence
            }
            transcriptHandler(composedTranscript(), sentence.sentenceEnd)

        case "task-finished":
            didFinish = true
            finishTimeoutTask?.cancel()
            finishTimeoutTask = nil
            finishWaiter?.resume()
            finishWaiter = nil

        case "task-failed":
            let detail = message.header.errorMessage
                ?? message.header.errorCode
                ?? "未知错误"
            fail(AliyunSpeechServiceError.taskFailed("阿里云实时识别失败：\(detail)"))

        default:
            break
        }
    }

    private func composedTranscript() -> String {
        var sentences = finalSentences.values.sorted { lhs, rhs in
            lhs.sentenceID < rhs.sentenceID
        }
        if let interimSentence {
            sentences.append(interimSentence)
        }
        return sentences.map(\.text).joined()
    }

    private func decodingErrorDescription(_ error: Error) -> String {
        func path(_ codingPath: [any CodingKey], appending key: (any CodingKey)? = nil) -> String {
            let components = codingPath.map(\.stringValue)
                + (key.map { [$0.stringValue] } ?? [])
            return components.isEmpty ? "根节点" : components.joined(separator: ".")
        }

        switch error {
        case DecodingError.keyNotFound(let key, let context):
            return "缺少字段 \(path(context.codingPath, appending: key))"
        case DecodingError.valueNotFound(_, let context):
            return "字段 \(path(context.codingPath)) 的值为空"
        case DecodingError.typeMismatch(_, let context):
            return "字段 \(path(context.codingPath)) 的类型不正确"
        case DecodingError.dataCorrupted(let context):
            return "字段 \(path(context.codingPath)) 的数据损坏"
        default:
            return error.localizedDescription
        }
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
            self.fail(AliyunSpeechServiceError.timeout("阿里云实时识别连接超时。"))
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
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, let self, !self.didFinish else {
                return
            }
            self.fail(AliyunSpeechServiceError.timeout("阿里云实时识别收尾超时。"))
        }
        try await withCheckedThrowingContinuation { continuation in
            finishWaiter = continuation
        }
    }

    private func fail(_ error: Error) {
        guard terminalError == nil, !didFinish else {
            return
        }
        terminalError = error
        startTimeoutTask?.cancel()
        finishTimeoutTask?.cancel()
        startWaiter?.resume(throwing: error)
        finishWaiter?.resume(throwing: error)
        startWaiter = nil
        finishWaiter = nil
    }

    private func closeSocket() {
        startTimeoutTask?.cancel()
        finishTimeoutTask?.cancel()
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }

    private func runTaskMessage() throws -> String {
        var parameters: [String: Any] = [
            "format": "pcm",
            "sample_rate": 16_000,
            "language_hints": ["zh"],
            "semantic_punctuation_enabled": false,
            "max_sentence_silence": 700,
            "heartbeat": true
        ]
        if let vocabularyID = vocabulary.id {
            parameters["vocabulary_id"] = vocabularyID
        }
        let payload: [String: Any] = [
            "header": [
                "action": "run-task",
                "task_id": taskID,
                "streaming": "duplex"
            ],
            "payload": [
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": AliyunVocabularyTarget.realtime.model,
                "parameters": parameters,
                "input": [:] as [String: Any]
            ] as [String: Any]
        ]
        return String(
            decoding: try JSONSerialization.data(withJSONObject: payload),
            as: UTF8.self
        )
    }

    private func finishTaskMessage() throws -> String {
        let payload: [String: Any] = [
            "header": [
                "action": "finish-task",
                "task_id": taskID,
                "streaming": "duplex"
            ],
            "payload": ["input": [:] as [String: Any]]
        ]
        return String(
            decoding: try JSONSerialization.data(withJSONObject: payload),
            as: UTF8.self
        )
    }
}

final class AliyunRealtimeAudioCapture: @unchecked Sendable {
    typealias MeterHandler = @MainActor @Sendable (Double, TimeInterval) -> Void

    private let engine = AVAudioEngine()
    private let audioContinuation: AsyncStream<Data>.Continuation
    private let meterHandler: MeterHandler
    private let stateLock = NSLock()
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var totalOutputFrames: AVAudioFramePosition = 0
    private var isStopped = false

    init(
        fileURL: URL,
        audioContinuation: AsyncStream<Data>.Continuation,
        meterHandler: @escaping MeterHandler
    ) throws {
        self.audioContinuation = audioContinuation
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
            throw AliyunSpeechServiceError.configuration("无法准备实时录音音频转换器。")
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
        audioContinuation.finish()
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

        let inputState = AudioConverterInputState(buffer: inputBuffer)
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
        audioContinuation.yield(pcm.withUnsafeBytes { Data($0) })
        Task { @MainActor [meterHandler] in
            meterHandler(decibels, duration)
        }
    }
}

private final class AudioConverterInputState: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var didSupply = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

private struct RealtimeServerEnvelope: Decodable {
    let header: Header
    let payload: Payload?

    struct Header: Decodable {
        let event: String
        let errorCode: String?
        let errorMessage: String?

        enum CodingKeys: String, CodingKey {
            case event
            case errorCode = "error_code"
            case errorMessage = "error_message"
        }
    }

    struct Payload: Decodable {
        let output: Output?
        let usage: Usage?
    }

    struct Output: Decodable {
        let sentence: RealtimeSentence?
    }

    struct Usage: Decodable {
        let duration: Int?
    }
}

private struct RealtimeSentence: Decodable {
    let beginTime: Int
    let endTime: Int?
    let text: String
    let heartbeat: Bool
    let sentenceEnd: Bool
    let sentenceID: Int
    let words: [RealtimeWord]?

    enum CodingKeys: String, CodingKey {
        case beginTime = "begin_time"
        case endTime = "end_time"
        case text
        case heartbeat
        case sentenceEnd = "sentence_end"
        case sentenceID = "sentence_id"
        case words
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        heartbeat = try container.decodeIfPresent(Bool.self, forKey: .heartbeat) ?? false

        // 心跳包可能只携带 heartbeat 与 sentence_id，不应按普通句子强制解码。
        guard !heartbeat else {
            beginTime = 0
            endTime = nil
            text = ""
            sentenceEnd = false
            sentenceID = try container.decodeIfPresent(Int.self, forKey: .sentenceID) ?? 0
            words = nil
            return
        }

        beginTime = try container.decodeIfPresent(Int.self, forKey: .beginTime) ?? 0
        endTime = try container.decodeIfPresent(Int.self, forKey: .endTime)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        sentenceEnd = try container.decodeIfPresent(Bool.self, forKey: .sentenceEnd)
            ?? (endTime != nil)
        sentenceID = try container.decodeIfPresent(Int.self, forKey: .sentenceID) ?? 0
        words = try container.decodeIfPresent([RealtimeWord].self, forKey: .words)
    }
}

private struct RealtimeWord: Decodable {
    let beginTime: Int
    let endTime: Int
    let text: String
    let punctuation: String?

    enum CodingKeys: String, CodingKey {
        case beginTime = "begin_time"
        case endTime = "end_time"
        case text
        case punctuation
    }
}
