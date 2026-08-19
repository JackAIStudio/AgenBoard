import Foundation

// 运行方式：
// test_dir=$(mktemp -d) && xcrun swiftc -swift-version 6 \
//   scripts/validate-hotword-policy.swift AgenBoard/HotwordLibrary.swift \
//   -o "$test_dir/validate-hotword-policy" && \
//   "$test_dir/validate-hotword-policy"
//
// 这个轻量测试直接与 AgenBoard/HotwordLibrary.swift 一起编译。
// 这里只补齐该文件依赖的最小类型，避免为了纯策略测试启动完整 iOS App。
enum SpeechRecognitionProvider: String, Codable, Sendable {
    case apple
    case volcRealtime
    case aliyun
    case aliyunRealtime

    var primaryProvider: SpeechRecognitionProvider {
        switch self {
        case .aliyun, .aliyunRealtime:
            return .volcRealtime
        case .apple, .volcRealtime:
            return self
        }
    }
}

enum SharedCommandStore {
    static let appGroupIdentifier = "dev.local.agenboard.hotword-policy-test"
}

@main
struct HotwordPolicyValidation {
    static func main() {
        validatesVolcPreservesExpectedOutputFormat()
        validatesVolcFiveThousandTermBoundary()
        validatesAppleHundredTermBoundary()
        validatesDisabledTermsAreSkippedWithoutReordering()
        validatesLegacyPriorityMetadataIsIgnored()
        print("HotwordSelectionPolicy validation passed")
    }

    private static func validatesVolcPreservesExpectedOutputFormat() {
        let terms = ["A roll", "AGENTS.md", "奥迪A4L", "Vibe Coding"]
        let plan = HotwordSelectionPolicy.plan(
            from: terms,
            provider: .volcRealtime
        )

        expect(
            plan.acceptedTerms == terms,
            "火山 Context 直传必须保留用户期望的空格、标点、大小写和数字"
        )
        expect(plan.exclusions.isEmpty, "合法格式不应被排除")
    }

    private static func validatesVolcFiveThousandTermBoundary() {
        let terms = (0..<5_002).map { "term-\($0)" }
        let plan = HotwordSelectionPolicy.plan(
            from: terms,
            provider: .volcRealtime
        )

        expect(plan.acceptedTerms.count == 5_000, "火山二遍应接收前 5000 个热词")
        expect(plan.acceptedTerms.last == "term-4999", "火山截断位置错误")
        expect(plan.exclusions.count == 2, "超出火山上限的词数错误")
        expect(
            plan.exclusions.allSatisfy { $0.reason == .countLimit },
            "火山溢出词应标记为数量限制"
        )
    }

    private static func validatesAppleHundredTermBoundary() {
        let terms = (0..<102).map { "apple-\($0)" }
        let plan = HotwordSelectionPolicy.plan(from: terms, provider: .apple)

        expect(plan.acceptedTerms.count == 100, "Apple 仍应只接收前 100 个热词")
        expect(plan.exclusions.count == 2, "Apple 溢出词数错误")
    }

    private static func validatesDisabledTermsAreSkippedWithoutReordering() {
        let first = HotwordEntry(term: "第一个")
        let disabled = HotwordEntry(term: "停用", isEnabled: false)
        let third = HotwordEntry(term: "第三个")
        let plan = HotwordSelectionPolicy.plan(
            from: [first, disabled, third],
            provider: .volcRealtime
        )
        expect(
            plan.acceptedTerms == ["第一个", "第三个"],
            "停用热词应被跳过，其他热词不应被自动重排"
        )
    }

    private static func validatesLegacyPriorityMetadataIsIgnored() {
        let legacy = LegacyHotwordEntry(
            id: UUID(),
            term: "旧版热词",
            isPinned: true,
            isEnabled: true,
            lastUsedAt: Date(),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let data = try! JSONEncoder().encode(legacy)
        let decoded = try! JSONDecoder().decode(HotwordEntry.self, from: data)

        expect(decoded.id == legacy.id, "旧版热词 ID 应保留")
        expect(decoded.term == legacy.term, "旧版热词文本应保留")
        expect(decoded.isEnabled, "旧版热词启用状态应保留")
    }

    private struct LegacyHotwordEntry: Codable {
        let id: UUID
        let term: String
        let isPinned: Bool
        let isEnabled: Bool
        let lastUsedAt: Date?
        let createdAt: Date
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fatalError(message)
        }
    }
}
