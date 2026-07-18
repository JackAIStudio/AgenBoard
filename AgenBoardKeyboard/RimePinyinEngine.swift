import Foundation
import LibrimeKit
import os

/// Serializes access to librime's process-global session and keeps its user
/// dictionary in the shared App Group container. The bundled static dictionary
/// is read-only; only learned user data is written at runtime.
final class RimePinyinEngine: @unchecked Sendable {
    static let shared = RimePinyinEngine()

    private enum State: Equatable {
        case idle
        case preparing
        case ready
        case failed
    }

    private let lock = NSLock()
    private let logger = Logger(
        subsystem: "dev.local.agenboard.keyboard",
        category: "RimePinyin"
    )
    private let rime = Rime.shared
    private var state = State.idle

    private init() {}

    @discardableResult
    func prepare() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        switch state {
        case .ready:
            return true
        case .failed:
            return false
        case .preparing:
            return false
        case .idle:
            state = .preparing
        }

        do {
            let fileManager = FileManager.default
            guard let sharedDataURL = Bundle.main.url(
                forResource: "RimeData",
                withExtension: nil
            ) else {
                throw PreparationError.missingBundledData
            }

            let prebuiltDataURL = sharedDataURL.appendingPathComponent(
                "Prebuilt",
                isDirectory: true
            )
            guard fileManager.fileExists(
                atPath: prebuiltDataURL
                    .appendingPathComponent("rime_ice.table.bin")
                    .path
            ) else {
                throw PreparationError.missingPrebuiltDictionary
            }

            let containerURL = fileManager.containerURL(
                forSecurityApplicationGroupIdentifier:
                    SharedCommandStore.appGroupIdentifier
            ) ?? fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            let userDataURL = containerURL.appendingPathComponent(
                "RimeUserData",
                isDirectory: true
            )
            let stagingURL = userDataURL.appendingPathComponent(
                "Build",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: userDataURL,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: stagingURL,
                withIntermediateDirectories: true
            )

            let traits = Rime.createTraits(
                sharedSupportDir: sharedDataURL.path,
                userDataDir: userDataURL.path,
                models: ["core", "dict", "gears"]
            )
            traits.distributionCodeName = "AgenBoard"
            traits.distributionName = "AgenBoard 拼音"
            traits.prebuiltDataDir = prebuiltDataURL.path
            traits.stagingDir = stagingURL.path
            traits.minLogLevel = 2

            // Static data is precompiled with the matching librime version, so
            // maintenance must remain off inside the memory-limited extension.
            rime.start(traits, maintenance: false)
            rime.createSession()
            guard rime.setSchema("agenboard_pinyin") else {
                throw PreparationError.cannotSelectSchema
            }
            _ = rime.asciiMode(false)
            rime.cleanComposition()
            state = .ready
            logger.notice("Rime 拼音引擎已就绪")
            return true
        } catch {
            state = .failed
            logger.error("Rime 拼音引擎初始化失败：\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Returns nil only when Rime is unavailable, allowing the small legacy
    /// engine to remain a last-resort fallback.
    func candidates(for composition: String, limit: Int) -> [String]? {
        lock.lock()
        defer { lock.unlock() }

        guard state == .ready else {
            return nil
        }
        let normalized = Self.normalizedLetters(composition)
        guard !normalized.isEmpty, limit > 0 else {
            rime.cleanComposition()
            return []
        }
        guard synchronizeComposition(to: normalized) else {
            return nil
        }

        var seen = Set<String>()
        return rime.candidateList().compactMap { candidate in
            guard !candidate.text.isEmpty,
                  seen.insert(candidate.text).inserted else {
                return nil
            }
            return candidate.text
        }.prefix(limit).map { $0 }
    }

    /// Selects through librime rather than merely inserting the visible text.
    /// This is the operation that updates Rime's persistent user dictionary.
    func selectCandidate(
        _ candidate: String,
        for composition: String
    ) -> String? {
        lock.lock()
        defer { lock.unlock() }

        guard state == .ready else {
            return nil
        }
        let normalized = Self.normalizedLetters(composition)
        guard !normalized.isEmpty,
              synchronizeComposition(to: normalized) else {
            return nil
        }

        let candidates = rime.candidateList()
        guard let index = candidates.firstIndex(where: {
            $0.text == candidate
        }), rime.selectCandidateOnCurrentPage(index: index) else {
            rime.cleanComposition()
            return nil
        }

        var committedText = rime.getCommitText()
        if committedText.isEmpty, !rime.getInputKeys().isEmpty,
           rime.commitComposition() {
            // A short candidate can select only the first segment. Committing
            // the remaining composition preserves today's one-tap UI contract
            // while still letting Rime learn the explicit segment choice.
            committedText = rime.getCommitText()
        }
        rime.cleanComposition()
        return committedText.isEmpty ? candidate : committedText
    }

    func resetComposition() {
        lock.lock()
        defer { lock.unlock() }
        guard state == .ready else {
            return
        }
        rime.cleanComposition()
    }

    private func synchronizeComposition(to desiredInput: String) -> Bool {
        let currentInput = rime.getInputKeys()
        if currentInput == desiredInput {
            return true
        }

        if desiredInput.hasPrefix(currentInput) {
            for character in desiredInput.dropFirst(currentInput.count) {
                guard rime.inputKey(String(character)) else {
                    return false
                }
            }
        } else if currentInput.hasPrefix(desiredInput) {
            let deletionCount = currentInput.count - desiredInput.count
            for _ in 0..<deletionCount {
                guard rime.inputKeyCode(0xFF08) else {
                    return false
                }
            }
        } else {
            rime.cleanComposition()
            for character in desiredInput {
                guard rime.inputKey(String(character)) else {
                    return false
                }
            }
        }

        return rime.getInputKeys() == desiredInput
    }

    private static func normalizedLetters(_ text: String) -> String {
        text.lowercased().unicodeScalars.compactMap { scalar in
            guard (97...122).contains(scalar.value) else {
                return nil
            }
            return String(scalar)
        }.joined()
    }

    private enum PreparationError: LocalizedError {
        case missingBundledData
        case missingPrebuiltDictionary
        case cannotSelectSchema

        var errorDescription: String? {
            switch self {
            case .missingBundledData:
                return "应用包内缺少 RimeData"
            case .missingPrebuiltDictionary:
                return "应用包内缺少预编译词典"
            case .cannotSelectSchema:
                return "无法启用 AgenBoard 拼音方案"
            }
        }
    }
}
