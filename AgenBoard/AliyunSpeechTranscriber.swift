import Foundation

enum AliyunVocabularyTarget: Sendable {
    case file
    case realtime

    var model: String {
        switch self {
        case .file:
            return "fun-asr"
        case .realtime:
            return "fun-asr-realtime"
        }
    }

    var cachedID: String? {
        switch self {
        case .file:
            return SpeechServicePreferences.cachedAliyunVocabularyID
        case .realtime:
            return SpeechServicePreferences.cachedAliyunRealtimeVocabularyID
        }
    }

    var cachedFingerprint: String? {
        switch self {
        case .file:
            return SpeechServicePreferences.cachedAliyunVocabularyFingerprint
        case .realtime:
            return SpeechServicePreferences.cachedAliyunRealtimeVocabularyFingerprint
        }
    }

    func cache(id: String, fingerprint: String) {
        switch self {
        case .file:
            SpeechServicePreferences.cacheAliyunVocabulary(id: id, fingerprint: fingerprint)
        case .realtime:
            SpeechServicePreferences.cacheAliyunRealtimeVocabulary(
                id: id,
                fingerprint: fingerprint
            )
        }
    }

    func clearCache() {
        switch self {
        case .file:
            SpeechServicePreferences.clearAliyunFileVocabularyCache()
        case .realtime:
            SpeechServicePreferences.clearAliyunRealtimeVocabularyCache()
        }
    }
}

struct AliyunVocabularySetup: Sendable {
    let id: String?
    let acceptedTerms: [String]
    let ignoredTerms: [String]
}

@MainActor
enum AliyunSpeechTranscriber {
    private static let vocabularyWeight = 5

    static func transcribe(
        audioURL: URL,
        hotwords: [String],
        progress: (String) -> Void
    ) async throws -> SpeechRecognitionServiceOutput {
        try Task.checkCancellation()
        let startedAt = Date()
        let configuration = try AliyunSpeechConfiguration.load()

        progress("阿里云 · 正在同步热词")
        var stageStartedAt = Date()
        let vocabulary = try await ensureVocabulary(
            hotwords: hotwords,
            target: .file,
            configuration: configuration
        )
        let vocabularyElapsed = Date().timeIntervalSince(stageStartedAt)

        progress("阿里云 · 正在获取临时上传凭证")
        stageStartedAt = Date()
        let uploadPolicy = try await fetchUploadPolicy(configuration: configuration)
        let uploadPolicyElapsed = Date().timeIntervalSince(stageStartedAt)

        progress("阿里云 · 正在上传录音")
        stageStartedAt = Date()
        let temporaryAudioURL = try await uploadAudio(
            at: audioURL,
            policy: uploadPolicy
        )
        let uploadTransferElapsed = Date().timeIntervalSince(stageStartedAt)

        progress("阿里云 · 正在提交识别")
        stageStartedAt = Date()
        let taskID = try await submitTranscription(
            audioURL: temporaryAudioURL,
            vocabularyID: vocabulary.id,
            configuration: configuration
        )
        let taskSubmissionElapsed = Date().timeIntervalSince(stageStartedAt)

        progress("阿里云 · 正在识别整段录音")
        stageStartedAt = Date()
        let resultURL = try await waitForTranscription(
            taskID: taskID,
            configuration: configuration
        )
        let cloudProcessingElapsed = Date().timeIntervalSince(stageStartedAt)

        progress("阿里云 · 正在下载识别结果")
        stageStartedAt = Date()
        let document = try await downloadTranscription(from: resultURL)
        let resultDownloadElapsed = Date().timeIntervalSince(stageStartedAt)
        let transcript = document.transcripts.map(\.text).joined()
        let words = document.transcripts.flatMap { transcript in
            (transcript.sentences ?? []).flatMap { sentence in
                (sentence.words ?? []).map { word in
                    SpeechRecognitionWord(
                        text: word.text,
                        beginTimeMilliseconds: word.beginTime,
                        endTimeMilliseconds: word.endTime,
                        punctuation: word.punctuation
                    )
                }
            }
        }

        return SpeechRecognitionServiceOutput(
            transcript: transcript,
            elapsed: Date().timeIntervalSince(startedAt),
            words: words,
            configuredHotwordCount: vocabulary.acceptedTerms.count,
            ignoredHotwords: vocabulary.ignoredTerms,
            fileMetrics: AliyunFileRecognitionMetrics(
                vocabularyElapsed: vocabularyElapsed,
                uploadPolicyElapsed: uploadPolicyElapsed,
                uploadTransferElapsed: uploadTransferElapsed,
                taskSubmissionElapsed: taskSubmissionElapsed,
                cloudProcessingElapsed: cloudProcessingElapsed,
                resultDownloadElapsed: resultDownloadElapsed
            )
        )
    }

    static func validateConfiguration() async throws {
        let configuration = try AliyunSpeechConfiguration.load()
        _ = try await fetchUploadPolicy(configuration: configuration)

        let url = configuration.apiBaseURL
            .appendingPathComponent("services/audio/asr/customization")
        let payload: [String: Any] = [
            "model": "speech-biasing",
            "input": [
                "action": "list_vocabulary",
                "prefix": "agenboard",
                "page_index": 0,
                "page_size": 1
            ]
        ]
        let request = try jsonRequest(
            url: url,
            apiKey: configuration.apiKey,
            payload: payload
        )
        _ = try await send(request)
    }

    static func prepareVocabulary(
        hotwords: [String],
        target: AliyunVocabularyTarget
    ) async throws -> AliyunVocabularySetup {
        try await ensureVocabulary(
            hotwords: hotwords,
            target: target,
            configuration: try AliyunSpeechConfiguration.load()
        )
    }

    private static func ensureVocabulary(
        hotwords: [String],
        target: AliyunVocabularyTarget,
        configuration: AliyunSpeechConfiguration
    ) async throws -> AliyunVocabularySetup {
        let acceptedTerms = validVocabularyTerms(from: hotwords)
        let acceptedKeys = Set(acceptedTerms.map(HotwordLibraryStorage.comparisonKey))
        let ignoredTerms = hotwords.filter {
            !acceptedKeys.contains(HotwordLibraryStorage.comparisonKey($0))
        }

        guard !acceptedTerms.isEmpty else {
            return AliyunVocabularySetup(
                id: nil,
                acceptedTerms: [],
                ignoredTerms: ignoredTerms
            )
        }

        let fingerprint = vocabularyFingerprint(
            terms: acceptedTerms,
            target: target,
            baseURL: configuration.apiBaseURL
        )

        if let cachedID = target.cachedID {
            do {
                let state = try await queryVocabulary(
                    id: cachedID,
                    configuration: configuration
                )
                guard state.targetModel == nil || state.targetModel == target.model else {
                    target.clearCache()
                    return try await createVocabulary(
                        terms: acceptedTerms,
                        ignoredTerms: ignoredTerms,
                        fingerprint: fingerprint,
                        target: target,
                        configuration: configuration
                    )
                }

                let needsUpdate = target.cachedFingerprint != fingerprint
                if needsUpdate {
                    try await updateVocabulary(
                        id: cachedID,
                        terms: acceptedTerms,
                        configuration: configuration
                    )
                }
                try await waitForVocabulary(
                    id: cachedID,
                    initialState: needsUpdate ? nil : state.status,
                    configuration: configuration
                )
                target.cache(id: cachedID, fingerprint: fingerprint)
                return AliyunVocabularySetup(
                    id: cachedID,
                    acceptedTerms: acceptedTerms,
                    ignoredTerms: ignoredTerms
                )
            } catch let error as AliyunSpeechServiceError
                where error.permitsVocabularyRecreation {
                target.clearCache()
            }
        }

        return try await createVocabulary(
            terms: acceptedTerms,
            ignoredTerms: ignoredTerms,
            fingerprint: fingerprint,
            target: target,
            configuration: configuration
        )
    }

    private static func createVocabulary(
        terms: [String],
        ignoredTerms: [String],
        fingerprint: String,
        target: AliyunVocabularyTarget,
        configuration: AliyunSpeechConfiguration
    ) async throws -> AliyunVocabularySetup {
        let input: [String: Any] = [
            "action": "create_vocabulary",
            "target_model": target.model,
            "prefix": "agenboard",
            "vocabulary": vocabularyPayload(terms)
        ]
        let response: VocabularyCreateEnvelope = try await sendJSON(
            try customizationRequest(input: input, configuration: configuration)
        )
        let id = response.output.vocabularyID
        try await waitForVocabulary(
            id: id,
            initialState: nil,
            configuration: configuration
        )
        target.cache(id: id, fingerprint: fingerprint)
        return AliyunVocabularySetup(
            id: id,
            acceptedTerms: terms,
            ignoredTerms: ignoredTerms
        )
    }

    private static func updateVocabulary(
        id: String,
        terms: [String],
        configuration: AliyunSpeechConfiguration
    ) async throws {
        let input: [String: Any] = [
            "action": "update_vocabulary",
            "vocabulary_id": id,
            "vocabulary": vocabularyPayload(terms)
        ]
        _ = try await send(
            try customizationRequest(input: input, configuration: configuration)
        )
    }

    private static func queryVocabulary(
        id: String,
        configuration: AliyunSpeechConfiguration
    ) async throws -> VocabularyQueryOutput {
        let response: VocabularyQueryEnvelope = try await sendJSON(
            try customizationRequest(
                input: [
                    "action": "query_vocabulary",
                    "vocabulary_id": id
                ],
                configuration: configuration
            )
        )
        return response.output
    }

    private static func waitForVocabulary(
        id: String,
        initialState: String?,
        configuration: AliyunSpeechConfiguration
    ) async throws {
        if initialState == "OK" {
            return
        }

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            try Task.checkCancellation()
            let state = try await queryVocabulary(id: id, configuration: configuration)
            if state.status == "OK" {
                return
            }
            try await Task.sleep(nanoseconds: 750_000_000)
        }
        throw AliyunSpeechServiceError.timeout("阿里云热词表部署超时，请稍后重试。")
    }

    private static func customizationRequest(
        input: [String: Any],
        configuration: AliyunSpeechConfiguration
    ) throws -> URLRequest {
        try jsonRequest(
            url: configuration.apiBaseURL
                .appendingPathComponent("services/audio/asr/customization"),
            apiKey: configuration.apiKey,
            payload: ["model": "speech-biasing", "input": input]
        )
    }

    private static func vocabularyPayload(_ terms: [String]) -> [[String: Any]] {
        terms.map { ["text": $0, "weight": vocabularyWeight] }
    }

    private static func validVocabularyTerms(from terms: [String]) -> [String] {
        var keys = Set<String>()
        return terms.compactMap { candidate in
            guard let term = HotwordLibraryStorage.normalizedTerm(candidate) else {
                return nil
            }
            let isASCII = term.unicodeScalars.allSatisfy(\.isASCII)
            if isASCII {
                let segments = term.split(whereSeparator: \.isWhitespace)
                guard !segments.isEmpty, segments.count <= 7 else {
                    return nil
                }
            } else if term.count > 15 {
                return nil
            }

            let key = HotwordLibraryStorage.comparisonKey(term)
            guard keys.insert(key).inserted else {
                return nil
            }
            return term
        }
    }

    private static func vocabularyFingerprint(
        terms: [String],
        target: AliyunVocabularyTarget,
        baseURL: URL
    ) -> String {
        let source = ([
            baseURL.absoluteString,
            "model=\(target.model)",
            "weight=\(vocabularyWeight)"
        ] + terms)
            .joined(separator: "\u{001F}")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private static func uploadAudio(
        at audioURL: URL,
        policy: UploadPolicy
    ) async throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        if let limit = policy.maxFileSizeMB,
           fileSize > Int64(limit) * 1_024 * 1_024 {
            throw AliyunSpeechServiceError.configuration(
                "录音大小超过阿里云临时上传上限 \(limit) MB。"
            )
        }

        let filename = "agenboard-\(UUID().uuidString).m4a"
        let objectKey = "\(policy.uploadDir)/\(filename)"
        let boundary = "AgenBoardBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var form = MultipartFormData(boundary: boundary)
        form.addField(name: "OSSAccessKeyId", value: policy.ossAccessKeyID)
        form.addField(name: "Signature", value: policy.signature)
        form.addField(name: "policy", value: policy.policy)
        form.addField(name: "x-oss-object-acl", value: policy.objectACL)
        form.addField(name: "x-oss-forbid-overwrite", value: policy.forbidOverwrite)
        form.addField(name: "key", value: objectKey)
        form.addField(name: "success_action_status", value: "200")
        try form.addFile(
            name: "file",
            filename: filename,
            mimeType: "audio/mp4",
            fileURL: audioURL
        )

        guard let uploadURL = URL(string: policy.uploadHost) else {
            throw AliyunSpeechServiceError.invalidResponse("阿里云返回了无效的上传地址。")
        }
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = form.finalizedData()
        _ = try await send(request)
        return "oss://\(objectKey)"
    }

    private static func fetchUploadPolicy(
        configuration: AliyunSpeechConfiguration
    ) async throws -> UploadPolicy {
        var components = URLComponents(
            url: AliyunSpeechConfiguration.uploadPolicyBaseURL
                .appendingPathComponent("uploads"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "action", value: "getPolicy"),
            URLQueryItem(name: "model", value: AliyunVocabularyTarget.file.model)
        ]
        guard let url = components?.url else {
            throw AliyunSpeechServiceError.invalidResponse("无法生成阿里云上传凭证地址。")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let response: UploadPolicyEnvelope = try await sendJSON(request)
        return response.data
    }

    private static func submitTranscription(
        audioURL: String,
        vocabularyID: String?,
        configuration: AliyunSpeechConfiguration
    ) async throws -> String {
        var parameters: [String: Any] = ["channel_id": [0]]
        if let vocabularyID {
            parameters["vocabulary_id"] = vocabularyID
        }
        let payload: [String: Any] = [
            "model": AliyunVocabularyTarget.file.model,
            "input": ["file_urls": [audioURL]],
            "parameters": parameters
        ]
        var request = try jsonRequest(
            url: configuration.apiBaseURL
                .appendingPathComponent("services/audio/asr/transcription"),
            apiKey: configuration.apiKey,
            payload: payload
        )
        request.setValue("enable", forHTTPHeaderField: "X-DashScope-Async")
        request.setValue("enable", forHTTPHeaderField: "X-DashScope-OssResourceResolve")
        let response: SubmitEnvelope = try await sendJSON(request)
        return response.output.taskID
    }

    private static func waitForTranscription(
        taskID: String,
        configuration: AliyunSpeechConfiguration
    ) async throws -> URL {
        let deadline = Date().addingTimeInterval(10 * 60)
        while Date() < deadline {
            try Task.checkCancellation()
            var request = URLRequest(
                url: configuration.apiBaseURL
                    .appendingPathComponent("tasks")
                    .appendingPathComponent(taskID)
            )
            request.httpMethod = "GET"
            request.setValue(
                "Bearer \(configuration.apiKey)",
                forHTTPHeaderField: "Authorization"
            )
            let response: TaskEnvelope = try await sendJSON(request)

            switch response.output.taskStatus {
            case "SUCCEEDED":
                guard let result = response.output.results?.first else {
                    throw AliyunSpeechServiceError.invalidResponse(
                        "阿里云任务成功，但没有返回音频转写结果。"
                    )
                }
                guard result.subtaskStatus == "SUCCEEDED" else {
                    throw AliyunSpeechServiceError.taskFailed(
                        "阿里云音频子任务失败：\(result.message ?? result.code ?? "未知错误")"
                    )
                }
                guard let value = result.transcriptionURL,
                      let url = URL(string: value) else {
                    throw AliyunSpeechServiceError.invalidResponse(
                        "阿里云没有返回有效的识别结果下载地址。"
                    )
                }
                return url
            case "FAILED", "CANCELED", "UNKNOWN":
                throw AliyunSpeechServiceError.taskFailed(
                    "阿里云识别任务失败：\(response.output.message ?? response.output.code ?? response.output.taskStatus)"
                )
            default:
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        throw AliyunSpeechServiceError.timeout("阿里云整段录音识别超时，请稍后重试。")
    }

    private static func downloadTranscription(from url: URL) async throws -> TranscriptionDocument {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return try await sendJSON(request)
    }

    private static func jsonRequest(
        url: URL,
        apiKey: String,
        payload: [String: Any]
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AliyunSpeechServiceError.invalidResponse("阿里云返回的响应无法解析。")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let payload = try? JSONDecoder().decode(APIErrorPayload.self, from: data)
            throw AliyunSpeechServiceError.http(
                status: httpResponse.statusCode,
                code: payload?.code,
                message: payload?.message ?? String(data: data, encoding: .utf8) ?? "未知错误"
            )
        }
        return data
    }

    private static func sendJSON<Response: Decodable>(
        _ request: URLRequest
    ) async throws -> Response {
        let data = try await send(request)
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw AliyunSpeechServiceError.invalidResponse(
                "阿里云响应字段与预期不一致：\(error.localizedDescription)"
            )
        }
    }
}

private struct MultipartFormData {
    let boundary: String
    private var data = Data()

    init(boundary: String) {
        self.boundary = boundary
    }

    mutating func addField(name: String, value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append("\(value)\r\n")
    }

    mutating func addFile(
        name: String,
        filename: String,
        mimeType: String,
        fileURL: URL
    ) throws {
        append("--\(boundary)\r\n")
        append(
            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
        )
        append("Content-Type: \(mimeType)\r\n\r\n")
        data.append(try Data(contentsOf: fileURL, options: .mappedIfSafe))
        append("\r\n")
    }

    mutating func finalizedData() -> Data {
        append("--\(boundary)--\r\n")
        return data
    }

    private mutating func append(_ value: String) {
        data.append(contentsOf: value.utf8)
    }
}

private struct APIErrorPayload: Decodable {
    let code: String?
    let message: String?
}

private struct UploadPolicyEnvelope: Decodable {
    let data: UploadPolicy
}

private struct UploadPolicy: Decodable {
    let policy: String
    let signature: String
    let uploadDir: String
    let uploadHost: String
    let ossAccessKeyID: String
    let objectACL: String
    let forbidOverwrite: String
    let maxFileSizeMB: Int?

    enum CodingKeys: String, CodingKey {
        case policy
        case signature
        case uploadDir = "upload_dir"
        case uploadHost = "upload_host"
        case ossAccessKeyID = "oss_access_key_id"
        case objectACL = "x_oss_object_acl"
        case forbidOverwrite = "x_oss_forbid_overwrite"
        case maxFileSizeMB = "max_file_size_mb"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        policy = try container.decode(String.self, forKey: .policy)
        signature = try container.decode(String.self, forKey: .signature)
        uploadDir = try container.decode(String.self, forKey: .uploadDir)
        uploadHost = try container.decode(String.self, forKey: .uploadHost)
        ossAccessKeyID = try container.decode(String.self, forKey: .ossAccessKeyID)
        objectACL = try container.decode(String.self, forKey: .objectACL)
        forbidOverwrite = try container.decode(String.self, forKey: .forbidOverwrite)
        if let value = try? container.decode(Int.self, forKey: .maxFileSizeMB) {
            maxFileSizeMB = value
        } else if let value = try? container.decode(String.self, forKey: .maxFileSizeMB) {
            maxFileSizeMB = Int(value)
        } else {
            maxFileSizeMB = nil
        }
    }
}

private struct VocabularyCreateEnvelope: Decodable {
    let output: Output

    struct Output: Decodable {
        let vocabularyID: String

        enum CodingKeys: String, CodingKey {
            case vocabularyID = "vocabulary_id"
        }
    }
}

private struct VocabularyQueryEnvelope: Decodable {
    let output: VocabularyQueryOutput
}

private struct VocabularyQueryOutput: Decodable {
    let status: String
    let targetModel: String?

    enum CodingKeys: String, CodingKey {
        case status
        case targetModel = "target_model"
    }
}

private struct SubmitEnvelope: Decodable {
    let output: Output

    struct Output: Decodable {
        let taskID: String

        enum CodingKeys: String, CodingKey {
            case taskID = "task_id"
        }
    }
}

private struct TaskEnvelope: Decodable {
    let output: Output

    struct Output: Decodable {
        let taskStatus: String
        let results: [Result]?
        let code: String?
        let message: String?

        enum CodingKeys: String, CodingKey {
            case taskStatus = "task_status"
            case results
            case code
            case message
        }
    }

    struct Result: Decodable {
        let transcriptionURL: String?
        let subtaskStatus: String
        let code: String?
        let message: String?

        enum CodingKeys: String, CodingKey {
            case transcriptionURL = "transcription_url"
            case subtaskStatus = "subtask_status"
            case code
            case message
        }
    }
}

private struct TranscriptionDocument: Decodable {
    let transcripts: [Transcript]

    struct Transcript: Decodable {
        let text: String
        let sentences: [Sentence]?
    }

    struct Sentence: Decodable {
        let words: [Word]?
    }

    struct Word: Decodable {
        let text: String
        let beginTime: Int
        let endTime: Int
        let punctuation: String?

        enum CodingKeys: String, CodingKey {
            case text
            case beginTime = "begin_time"
            case endTime = "end_time"
            case punctuation
        }
    }
}
