import Foundation
import Security

enum SpeechRecognitionProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case apple
    case aliyun

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple:
            return "Apple 本机识别"
        case .aliyun:
            return "阿里云 Fun-ASR"
        }
    }

    var shortTitle: String {
        switch self {
        case .apple:
            return "Apple"
        case .aliyun:
            return "阿里云"
        }
    }

    var systemImage: String {
        switch self {
        case .apple:
            return "apple.logo"
        case .aliyun:
            return "cloud"
        }
    }

    var detail: String {
        switch self {
        case .apple:
            return "本机处理 · 零 API 费用"
        case .aliyun:
            return "整段录音 · 动态热词权重 5"
        }
    }
}

struct SpeechRecognitionWord: Codable, Equatable, Sendable {
    let text: String
    let beginTimeMilliseconds: Int
    let endTimeMilliseconds: Int
    let punctuation: String?
}

struct SpeechRecognitionServiceOutput: Sendable {
    let transcript: String
    let elapsed: TimeInterval
    let words: [SpeechRecognitionWord]
    let configuredHotwordCount: Int
    let ignoredHotwords: [String]
}

enum SpeechServicePreferences {
    static let providerKey = "speechRecognitionProviderV1"
    private static let aliyunVocabularyIDKey = "aliyunSpeechVocabularyIDV1"
    private static let aliyunVocabularyFingerprintKey = "aliyunSpeechVocabularyFingerprintV1"

    nonisolated(unsafe) static let defaults =
        UserDefaults(suiteName: SharedCommandStore.appGroupIdentifier) ?? .standard

    static var provider: SpeechRecognitionProvider {
        get {
            guard let rawValue = defaults.string(forKey: providerKey),
                  let provider = SpeechRecognitionProvider(rawValue: rawValue) else {
                return .apple
            }
            return provider
        }
        set {
            defaults.set(newValue.rawValue, forKey: providerKey)
        }
    }

    static var cachedAliyunVocabularyID: String? {
        defaults.string(forKey: aliyunVocabularyIDKey)
    }

    static var cachedAliyunVocabularyFingerprint: String? {
        defaults.string(forKey: aliyunVocabularyFingerprintKey)
    }

    static func cacheAliyunVocabulary(id: String, fingerprint: String) {
        defaults.set(id, forKey: aliyunVocabularyIDKey)
        defaults.set(fingerprint, forKey: aliyunVocabularyFingerprintKey)
    }

    static func clearAliyunVocabularyCache() {
        defaults.removeObject(forKey: aliyunVocabularyIDKey)
        defaults.removeObject(forKey: aliyunVocabularyFingerprintKey)
    }
}

struct AliyunSpeechConfiguration: Sendable {
    let apiKey: String
    let apiBaseURL: URL

    static let dashScopeAPIBaseURL = URL(
        string: "https://dashscope.aliyuncs.com/api/v1"
    )!
    static let uploadPolicyBaseURL = dashScopeAPIBaseURL

    static func load() throws -> AliyunSpeechConfiguration {
        guard let apiKey = try AliyunCredentialStore.apiKey(), !apiKey.isEmpty else {
            throw AliyunSpeechServiceError.configuration(
                "尚未保存阿里云百炼 API Key，请先打开“识别服务”完成配置。"
            )
        }

        return AliyunSpeechConfiguration(
            apiKey: apiKey,
            apiBaseURL: dashScopeAPIBaseURL
        )
    }
}

extension Notification.Name {
    static let aliyunCredentialDidChange = Notification.Name(
        "dev.local.agenboard.aliyun-credential-did-change"
    )
}

enum AliyunCredentialStore {
    private static let service = "dev.local.agenboard.aliyun-speech"
    private static let account = "dashscope-api-key"

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
            throw AliyunSpeechServiceError.configuration("API Key 不能为空。")
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
        SpeechServicePreferences.clearAliyunVocabularyCache()
        NotificationCenter.default.post(name: .aliyunCredentialDidChange, object: nil)
    }

    static func deleteAPIKey() throws {
        try removeAPIKey()
        SpeechServicePreferences.clearAliyunVocabularyCache()
        NotificationCenter.default.post(name: .aliyunCredentialDidChange, object: nil)
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

enum AliyunSpeechServiceError: LocalizedError {
    case configuration(String)
    case invalidResponse(String)
    case http(status: Int, code: String?, message: String)
    case taskFailed(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .configuration(let message),
             .invalidResponse(let message),
             .taskFailed(let message),
             .timeout(let message):
            return message
        case .http(let status, let code, let message):
            let codeText = code.map { " · \($0)" } ?? ""
            return "阿里云请求失败（HTTP \(status)\(codeText)）：\(message)"
        }
    }

    var permitsVocabularyRecreation: Bool {
        guard case .http(let status, _, _) = self else {
            return false
        }
        return status == 400 || status == 404
    }
}
