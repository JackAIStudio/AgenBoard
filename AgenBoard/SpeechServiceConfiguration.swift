import Foundation
import Security

enum SpeechRecognitionProvider: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case apple
    case volcRealtime
    // 仅用于读取旧历史和旧导出包；新的云端请求不会再使用阿里云。
    case aliyun
    case aliyunRealtime

    var id: String { rawValue }

    /// 可在录音前选择的主识别方案。文件版仅用于识别历史的重新转写和失败恢复。
    static let primaryCases: [SpeechRecognitionProvider] = [
        .apple,
        .volcRealtime
    ]

    var primaryProvider: SpeechRecognitionProvider {
        switch self {
        case .aliyun, .aliyunRealtime:
            return .volcRealtime
        case .apple, .volcRealtime:
            return self
        }
    }

    var title: String {
        switch self {
        case .apple:
            if #available(iOS 26.0, *) {
                return "Apple 本机识别"
            }
            return "Apple 系统识别"
        case .volcRealtime:
            return "豆包流式语音识别 2.0"
        case .aliyun:
            return "阿里云 Fun-ASR 文件版（历史）"
        case .aliyunRealtime:
            return "阿里云 Fun-ASR 实时版（历史）"
        }
    }

    var shortTitle: String {
        switch self {
        case .apple:
            return "Apple"
        case .volcRealtime:
            return "豆包实时"
        case .aliyun:
            return "阿里文件"
        case .aliyunRealtime:
            return "阿里实时"
        }
    }

    var systemImage: String {
        switch self {
        case .apple:
            return "apple.logo"
        case .volcRealtime, .aliyunRealtime:
            return "waveform.badge.mic"
        case .aliyun:
            return "cloud"
        }
    }

    var detail: String {
        switch self {
        case .apple:
            if #available(iOS 26.0, *) {
                return "设备端处理 · 无需 API Key"
            }
            return "Apple Speech 兼容模式 · 无需 API Key"
        case .volcRealtime:
            return "实时上屏 + 停止后二遍终稿 · 使用你自己的 API Key"
        case .aliyun:
            return "云端整段异步识别 · 使用你自己的 API Key"
        case .aliyunRealtime:
            return "边录边识别 · 使用你自己的 API Key"
        }
    }

    var guidanceTitle: String {
        switch self {
        case .apple:
            return "速度和隐私优先"
        case .volcRealtime:
            return "中文准确度和实时反馈优先"
        case .aliyun:
            return "长录音和批量转写优先"
        case .aliyunRealtime:
            return "低等待和热词优先"
        }
    }

    var guidanceSummary: String {
        switch self {
        case .apple:
            return "适合聊天、随手记录和希望快速回填文字的日常场景。"
        case .volcRealtime:
            return "适合中文语音输入：边说边显示，停止后使用非流式二遍结果修正终稿。"
        case .aliyun:
            return "适合会议、访谈等长录音，停止后提交整段文件处理。"
        case .aliyunRealtime:
            return "适合聊天和语音输入，录音过程中同步转写，停止后只等待最终结果。"
        }
    }

    var guidanceStrengths: [String] {
        switch self {
        case .apple:
            if #available(iOS 26.0, *) {
                return [
                    "设备端 SpeechAnalyzer，通常返回更快",
                    "无需注册第三方服务，也没有单独的 API 调用费用",
                    "支持使用 AgenBoard 热词辅助识别"
                ]
            }
            return [
                "直接使用系统 Apple Speech 能力",
                "无需注册第三方服务，也没有单独的 API 调用费用",
                "支持使用 AgenBoard 热词辅助识别"
            ]
        case .volcRealtime:
            return [
                "使用 JackVoice 同款豆包双向流式优化版协议",
                "录音时实时上屏，停止后返回二遍识别终稿",
                "支持请求级热词直传，并返回字词时间戳"
            ]
        case .aliyun:
            return [
                "云端整段识别，通常更适合中文长录音与专业词场景",
                "支持同步最多 100 个已启用热词",
                "结果包含字词时间戳，便于后续校对"
            ]
        case .aliyunRealtime:
            return [
                "录音时同步发送和识别，显著缩短停止后的等待",
                "支持同步最多 100 个已启用热词",
                "返回实时文本和字词时间戳"
            ]
        }
    }

    var guidanceConsiderations: [String] {
        switch self {
        case .apple:
            if #available(iOS 26.0, *) {
                return [
                    "方言、噪声或专业词较多时，结果可能不如云端服务稳定",
                    "首次使用可能需要下载 Apple 中文语音模型"
                ]
            }
            return [
                "方言、噪声或专业词较多时，结果可能不如云端服务稳定",
                "iOS 17–25 使用 Apple Speech 兼容路径，联网需求由系统和设备能力决定"
            ]
        case .volcRealtime:
            return [
                "录音会在讲话过程中持续发送到火山引擎",
                "需要开通豆包流式语音识别模型 2.0，并使用你自己的 API Key",
                "弱网或切换网络可能中断当前实时识别任务"
            ]
        case .aliyun:
            return [
                "完整录音和已启用热词会发送到阿里云百炼处理",
                "需要联网，等待时间通常比设备端识别更长",
                "调用费用由你自己的百炼账号承担"
            ]
        case .aliyunRealtime:
            return [
                "录音会在讲话过程中持续发送到阿里云百炼",
                "弱网或切换网络可能中断当前实时识别任务",
                "单价高于文件版，调用费用由你自己的百炼账号承担"
            ]
        }
    }

    var privacySummary: String {
        switch self {
        case .apple:
            if #available(iOS 26.0, *) {
                return "录音由设备端 SpeechAnalyzer 处理，不会发送给项目维护者。"
            }
            return "录音由 Apple Speech 兼容路径处理，可能连接 Apple 服务，但不会发送给项目维护者。"
        case .volcRealtime:
            return "主 App 使用你的 API Key，通过 WebSocket 直连火山引擎；录音流和热词不会经过或发送给项目维护者。"
        case .aliyun:
            return "主 App 使用你的 API Key 直连阿里云百炼；录音和热词不会经过或发送给项目维护者。"
        case .aliyunRealtime:
            return "主 App 使用你的 API Key 通过 WebSocket 直连阿里云百炼；录音流和热词不会经过或发送给项目维护者。"
        }
    }

    var usesVolc: Bool {
        self == .volcRealtime
    }
}

enum VolcRealtimeTranscriptionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case naturalDictation
    case lowLatency

    var id: String { rawValue }

    var title: String {
        switch self {
        case .naturalDictation:
            return "自然听写"
        case .lowLatency:
            return "低延迟"
        }
    }

    var detail: String {
        switch self {
        case .naturalDictation:
            return "不按停顿强制判停，只在你停止录音后请求二遍终稿，适合边思考边说。"
        case .lowLatency:
            return "静音约 1.3 秒后生成确定句，反馈更快；较长的思考停顿可能提前断句。"
        }
    }

    var semanticPunctuationEnabled: Bool {
        true
    }

    var maxSentenceSilenceMilliseconds: Int? {
        self == .lowLatency ? 1_300 : nil
    }
}

struct SpeechRecognitionWord: Codable, Equatable, Sendable {
    let text: String
    let beginTimeMilliseconds: Int
    let endTimeMilliseconds: Int
    let punctuation: String?
}

struct LegacyFileRecognitionMetrics: Codable, Equatable, Sendable {
    let vocabularyElapsed: TimeInterval
    let uploadPolicyElapsed: TimeInterval
    let uploadTransferElapsed: TimeInterval
    let taskSubmissionElapsed: TimeInterval
    let cloudProcessingElapsed: TimeInterval
    let resultDownloadElapsed: TimeInterval
}

struct SpeechRecognitionServiceOutput: Sendable {
    let transcript: String
    let elapsed: TimeInterval
    let words: [SpeechRecognitionWord]
    let configuredHotwordCount: Int
    let ignoredHotwords: [String]
    let fileMetrics: LegacyFileRecognitionMetrics?

    init(
        transcript: String,
        elapsed: TimeInterval,
        words: [SpeechRecognitionWord],
        configuredHotwordCount: Int,
        ignoredHotwords: [String],
        fileMetrics: LegacyFileRecognitionMetrics? = nil
    ) {
        self.transcript = transcript
        self.elapsed = elapsed
        self.words = words
        self.configuredHotwordCount = configuredHotwordCount
        self.ignoredHotwords = ignoredHotwords
        self.fileMetrics = fileMetrics
    }
}

enum SpeechServicePreferences {
    static let providerKey = "speechRecognitionProviderV1"
    static let volcRealtimeTranscriptionModeKey =
        "volcRealtimeTranscriptionModeV1"
    static let volcResourceIDKey = "volcResourceIDV1"
    static let defaultVolcResourceID = "volc.seedasr.sauc.duration"
    // 用于从当前未提交版本平滑迁移，不再作为新设置写入。
    static let aliyunRealtimeTranscriptionModeKey =
        "aliyunRealtimeTranscriptionModeV1"

    nonisolated(unsafe) static let defaults =
        UserDefaults(suiteName: SharedCommandStore.appGroupIdentifier) ?? .standard

    static var provider: SpeechRecognitionProvider {
        get {
            guard let rawValue = defaults.string(forKey: providerKey),
                  let provider = SpeechRecognitionProvider(rawValue: rawValue) else {
                return .apple
            }
            let primaryProvider = provider.primaryProvider
            if primaryProvider != provider {
                defaults.set(primaryProvider.rawValue, forKey: providerKey)
            }
            return primaryProvider
        }
        set {
            defaults.set(newValue.primaryProvider.rawValue, forKey: providerKey)
        }
    }

    static var volcRealtimeTranscriptionMode: VolcRealtimeTranscriptionMode {
        get {
            if let rawValue = defaults.string(
                forKey: volcRealtimeTranscriptionModeKey
            ), let mode = VolcRealtimeTranscriptionMode(rawValue: rawValue) {
                return mode
            }
            if let legacyValue = defaults.string(
                forKey: aliyunRealtimeTranscriptionModeKey
            ), let mode = VolcRealtimeTranscriptionMode(rawValue: legacyValue) {
                defaults.set(mode.rawValue, forKey: volcRealtimeTranscriptionModeKey)
                return mode
            }
            return .naturalDictation
        }
        set {
            defaults.set(
                newValue.rawValue,
                forKey: volcRealtimeTranscriptionModeKey
            )
        }
    }

    static var volcResourceID: String {
        get {
            let value = defaults.string(forKey: volcResourceIDKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? defaultVolcResourceID : value
        }
        set {
            let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(
                value.isEmpty ? defaultVolcResourceID : value,
                forKey: volcResourceIDKey
            )
        }
    }

}

struct VolcSpeechConfiguration: Sendable {
    let apiKey: String
    let resourceID: String

    static let realtimeWebSocketURL = URL(
        string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
    )!

    static func load() throws -> VolcSpeechConfiguration {
        guard let apiKey = try VolcCredentialStore.apiKey(), !apiKey.isEmpty else {
            throw VolcSpeechServiceError.configuration(
                "尚未保存豆包语音 API Key，请先打开“识别服务”完成配置。"
            )
        }
        return VolcSpeechConfiguration(
            apiKey: apiKey,
            resourceID: SpeechServicePreferences.volcResourceID
        )
    }
}

extension Notification.Name {
    static let volcCredentialDidChange = Notification.Name(
        "dev.local.agenboard.volc-credential-did-change"
    )
}

enum VolcCredentialStore {
    private static let service = "dev.local.agenboard.volc-speech"
    private static let account = "volc-api-key"

    static var hasAPIKey: Bool {
        guard let key = try? apiKey() else {
            return false
        }
        return !key.isEmpty
    }

    static func apiKey() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainStorageError.status(status)
        }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainStorageError.invalidData
        }
        return value
    }

    static func saveAPIKey(_ value: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw VolcSpeechServiceError.configuration("API Key 不能为空。")
        }

        try removeAPIKey()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainStorageError.status(status)
        }
        NotificationCenter.default.post(name: .volcCredentialDidChange, object: nil)
    }

    static func deleteAPIKey() throws {
        try removeAPIKey()
        NotificationCenter.default.post(name: .volcCredentialDidChange, object: nil)
    }

    private static func removeAPIKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStorageError.status(status)
        }
    }
}

enum VolcSpeechServiceError: LocalizedError {
    case configuration(String)
    case invalidResponse(String)
    case taskFailed(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .configuration(let message),
             .invalidResponse(let message),
             .taskFailed(let message),
             .timeout(let message):
            return message
        }
    }
}

private enum KeychainStorageError: LocalizedError {
    case invalidData
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "钥匙串中的 API Key 数据无法读取。"
        case .status(let status):
            let message = SecCopyErrorMessageString(status, nil) as String?
            return "钥匙串操作失败：\(message ?? String(status))"
        }
    }
}
