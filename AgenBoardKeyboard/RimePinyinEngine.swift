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
    private var indexedComposition = ""
    private var candidateIndexByText: [String: Int] = [:]

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
    func firstCandidatePage(
        for composition: String,
        limit: Int
    ) -> PinyinCandidatePage? {
        lock.lock()
        defer { lock.unlock() }

        guard state == .ready else {
            return nil
        }
        let normalized = Self.normalizedLetters(composition)
        guard !normalized.isEmpty, limit > 0 else {
            rime.cleanComposition()
            resetCandidateIndex()
            return PinyinCandidatePage(
                candidates: [],
                hasMore: false,
                nextOffset: 0
            )
        }
        guard synchronizeComposition(to: normalized) else {
            return nil
        }
        guard rewindToFirstCandidatePage() else {
            return nil
        }
        indexedComposition = normalized
        candidateIndexByText.removeAll(keepingCapacity: true)

        return candidatePage(offset: 0, limit: limit)
    }

    func nextCandidatePage(
        for composition: String,
        offset: Int,
        limit: Int
    ) -> PinyinCandidatePage? {
        lock.lock()
        defer { lock.unlock() }

        guard state == .ready else {
            return nil
        }
        let normalized = Self.normalizedLetters(composition)
        guard !normalized.isEmpty, offset >= 0, limit > 0,
              synchronizeComposition(to: normalized) else {
            return nil
        }

        if indexedComposition != normalized {
            indexedComposition = normalized
            candidateIndexByText.removeAll(keepingCapacity: true)
        }
        return candidatePage(offset: offset, limit: limit)
    }

    private func candidatePage(offset: Int, limit: Int) -> PinyinCandidatePage {
        // Librime's iterator offset is zero-based, so 48 starts the second
        // 48-candidate batch. Reading by offset avoids candidateList(), which
        // always starts from the global first candidate regardless of pageNo.
        let fetchedCandidates = rime.candidateListWithIndex(
            index: offset,
            andCount: limit + 1
        )
        let visibleCandidates = fetchedCandidates.prefix(limit)
        var candidates: [String] = []
        candidates.reserveCapacity(visibleCandidates.count)
        for (relativeIndex, candidate) in visibleCandidates.enumerated() {
            guard !candidate.text.isEmpty else {
                continue
            }
            candidates.append(candidate.text)
            candidateIndexByText[candidate.text] = offset + relativeIndex
        }
        let nextOffset = offset + visibleCandidates.count
        return PinyinCandidatePage(
            candidates: candidates,
            hasMore: fetchedCandidates.count > limit,
            nextOffset: nextOffset
        )
    }

    /// Selects through librime rather than merely inserting the visible text.
    /// A partial candidate keeps Rime composing unless the caller explicitly
    /// asks to accept the best conversion for every remaining segment.
    func selectCandidate(
        _ candidate: String,
        for composition: String,
        commitRemainingComposition: Bool
    ) -> PinyinCandidateSelection? {
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

        let candidateIndex: Int
        if indexedComposition == normalized,
           let indexedCandidate = candidateIndexByText[candidate] {
            candidateIndex = indexedCandidate
        } else if let indexedCandidate = rime.candidateList().firstIndex(where: {
            $0.text == candidate
        }) {
            candidateIndex = indexedCandidate
        } else {
            rime.cleanComposition()
            return nil
        }

        guard rewindToFirstCandidatePage() else {
            rime.cleanComposition()
            return nil
        }
        let pageSize = max(1, Int(rime.context().menu.pageSize))
        for _ in 0..<(candidateIndex / pageSize) {
            guard rime.changePage(backward: false) else {
                rime.cleanComposition()
                return nil
            }
        }
        let indexOnPage = candidateIndex % pageSize
        guard rime.selectCandidateOnCurrentPage(index: indexOnPage) else {
            rime.cleanComposition()
            return nil
        }

        var committedText = rime.getCommitText()
        if committedText.isEmpty,
           commitRemainingComposition,
           !rime.getInputKeys().isEmpty {
            guard rime.commitComposition() else {
                rime.cleanComposition()
                resetCandidateIndex()
                return nil
            }
            committedText = rime.getCommitText()
        }

        if !committedText.isEmpty || rime.getInputKeys().isEmpty {
            rime.cleanComposition()
            resetCandidateIndex()
            return .committed(committedText.isEmpty ? candidate : committedText)
        }

        let markedText = rime.context().composition.preedit ?? ""
        resetCandidateIndex()
        return .composing(markedText: markedText.isEmpty ? candidate : markedText)
    }

    func markedText(for composition: String) -> String? {
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
        let preedit = rime.context().composition.preedit ?? ""
        return preedit.isEmpty ? normalized : preedit
    }

    func resetComposition() {
        lock.lock()
        defer { lock.unlock() }
        guard state == .ready else {
            return
        }
        rime.cleanComposition()
        resetCandidateIndex()
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

    private func rewindToFirstCandidatePage() -> Bool {
        while rime.context().menu.pageNo > 0 {
            guard rime.changePage(backward: true) else {
                return false
            }
        }
        return true
    }

    private func resetCandidateIndex() {
        indexedComposition = ""
        candidateIndexByText.removeAll(keepingCapacity: true)
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
