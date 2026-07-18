@preconcurrency import AVFoundation
import Foundation
import OSLog
import Speech

@available(iOS 26.0, *)
enum AppleSpeechTranscriber {
    struct Output: Sendable {
        let transcript: String
        let elapsed: TimeInterval
    }

    static func prepareLocale() async throws -> Locale {
        SpeechTranscriptionDiagnostics.logger.notice(
            "Preparing DictationTranscriber locale and assets"
        )
        let preferredLocales = [
            Locale(identifier: "zh_CN"),
            Locale(identifier: "zh-Hans-CN"),
            Locale(identifier: "zh-Hans")
        ]
        var resolvedLocale: Locale?

        for locale in preferredLocales {
            if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
                resolvedLocale = supported
                break
            }
        }

        guard let resolvedLocale else {
            throw AppleSpeechTranscriptionError.unavailable(
                "当前设备不支持 DictationTranscriber 中文模型。"
            )
        }

        let transcriber = DictationTranscriber(locale: resolvedLocale, preset: .longDictation)
        let status = await AssetInventory.status(forModules: [transcriber])
        guard status != .unsupported else {
            throw AppleSpeechTranscriptionError.unavailable("当前设备不支持所需的听写模型。")
        }

        if status != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            SpeechTranscriptionDiagnostics.logger.notice(
                "Downloading DictationTranscriber assets"
            )
            try await request.downloadAndInstall()
        }

        SpeechTranscriptionDiagnostics.logger.notice(
            "DictationTranscriber is ready for locale: \(resolvedLocale.identifier, privacy: .public)"
        )
        return resolvedLocale
    }

    static func transcribe(
        audioURL: URL,
        locale: Locale,
        hotwords: [String]
    ) async throws -> Output {
        try Task.checkCancellation()
        let startedAt = Date()
        let activeHotwords = HotwordSelectionPolicy.limitedTerms(hotwords)
        let transcriber = DictationTranscriber(locale: locale, preset: .longDictation)
        let audioFile = try AVAudioFile(forReading: audioURL)
        guard audioFile.length > 0, audioFile.processingFormat.sampleRate > 0 else {
            throw AppleSpeechTranscriptionError.unavailable(
                "录音文件为空，SpeechAnalyzer 没有可识别的音频帧。"
            )
        }

        let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        let formatDescription = audioFile.processingFormat.description
        SpeechTranscriptionDiagnostics.logger.notice(
            "Starting file transcription: frames=\(audioFile.length), duration=\(duration, format: .fixed(precision: 2))s, requestedHotwords=\(hotwords.count), activeHotwords=\(activeHotwords.count), format=\(formatDescription, privacy: .public)"
        )

        async let transcript = collectText(from: transcriber)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        if !activeHotwords.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = activeHotwords
            try await analyzer.setContext(context)
        }

        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
            throw AppleSpeechTranscriptionError.unavailable(
                "SpeechAnalyzer 没有从录音文件中读到音频样本。"
            )
        }

        let finalTranscript = try await transcript
        let elapsed = Date().timeIntervalSince(startedAt)
        SpeechTranscriptionDiagnostics.logger.notice(
            "Finished file transcription: characters=\(finalTranscript.count), elapsed=\(elapsed, format: .fixed(precision: 2))s"
        )
        return Output(transcript: finalTranscript, elapsed: elapsed)
    }

    private static func collectText(from transcriber: DictationTranscriber) async throws -> String {
        var text = ""
        for try await result in transcriber.results where result.isFinal {
            text += String(result.text.characters)
        }
        return text
    }
}

@available(iOS 26.0, *)
enum SpeechTranscriptionDiagnostics {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.local.agenboard",
        category: "SpeechTranscription"
    )
}

private enum AppleSpeechTranscriptionError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return message
        }
    }
}
