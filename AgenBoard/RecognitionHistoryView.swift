@preconcurrency import AVFoundation
import Speech
import SwiftUI
import UIKit

struct RecognitionHistoryListView: View {
    @ObservedObject var store: RecognitionHistoryStore

    @State private var pendingDeleteOffsets = IndexSet()
    @State private var showsDeleteConfirmation = false
    @State private var alertMessage = ""
    @State private var showsAlert = false

    var body: some View {
        List {
            if !store.storageMessage.isEmpty {
                Section {
                    Label(store.storageMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            if store.items.isEmpty {
                ContentUnavailableView(
                    "还没有识别历史",
                    systemImage: "waveform",
                    description: Text("完成一次录音后会自动保存在这里。")
                )
            } else {
                Section {
                    ForEach(store.items) { item in
                        NavigationLink {
                            RecognitionHistoryDetailView(store: store, itemID: item.id)
                        } label: {
                            RecognitionHistoryRow(item: item)
                        }
                    }
                    .onDelete { offsets in
                        pendingDeleteOffsets = offsets
                        showsDeleteConfirmation = true
                    }
                } header: {
                    HStack {
                        Text("全部录音")
                        Spacer()
                        Text("\(store.items.count) 条")
                    }
                }
            }
        }
        .navigationTitle("识别历史")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !store.items.isEmpty {
                EditButton()
            }
        }
        .confirmationDialog(
            "删除选中的录音和转写？",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                deletePendingItems()
            }
            Button("取消", role: .cancel) {
                pendingDeleteOffsets = IndexSet()
            }
        }
        .alert("识别历史", isPresented: $showsAlert) {
            Button("好") {}
        } message: {
            Text(alertMessage)
        }
    }

    private func deletePendingItems() {
        do {
            try store.delete(at: pendingDeleteOffsets)
        } catch {
            alertMessage = "删除失败：\(error.localizedDescription)"
            showsAlert = true
        }
        pendingDeleteOffsets = IndexSet()
    }
}

private struct RecognitionHistoryRow: View {
    let item: RecognitionHistoryItem

    private var previewText: String {
        if let originalMode = item.originalMode,
           let transcript = item.transcript(for: originalMode),
           !transcript.isEmpty {
            return transcript
        }
        if let transcript = item.transcriptWithHotwords, !transcript.isEmpty {
            return transcript
        }
        if let transcript = item.transcriptWithoutHotwords, !transcript.isEmpty {
            return transcript
        }
        return "待转写"
    }

    private var resultStatus: String {
        if item.transcriptWithHotwords != nil && item.transcriptWithoutHotwords != nil {
            return "两组已完成"
        }
        if let mode = item.originalMode, item.transcript(for: mode) != nil {
            return mode.title
        }
        if item.transcriptWithHotwords != nil {
            return RecognitionHotwordMode.withHotwords.title
        }
        if item.transcriptWithoutHotwords != nil {
            return RecognitionHotwordMode.withoutHotwords.title
        }
        return "未测试"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text(HistoryFormatting.duration(item.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(previewText)
                .font(.subheadline)
                .foregroundStyle(previewText == "待转写" ? .secondary : .primary)
                .lineLimit(2)

            HStack(spacing: 8) {
                Text(resultStatus)
                Text("·")
                Text(
                    item.hasRecording
                        ? HistoryFormatting.fileSize(item.fileSize)
                        : "仅转写文本"
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct RecognitionHistoryDetailView: View {
    @ObservedObject var store: RecognitionHistoryStore
    let itemID: UUID

    @AppStorage(
        SpeechServicePreferences.providerKey,
        store: SpeechServicePreferences.defaults
    ) private var providerRawValue = SpeechRecognitionProvider.apple.rawValue

    @StateObject private var playback = RecognitionHistoryPlaybackController()
    @State private var selectedMode = RecognitionHotwordMode.withHotwords
    @State private var isRunning = false
    @State private var runningStatus = ""
    @State private var alertMessage = ""
    @State private var showsAlert = false

    private var item: RecognitionHistoryItem? {
        store.item(id: itemID)
    }

    private var selectedProvider: SpeechRecognitionProvider {
        SpeechRecognitionProvider(rawValue: providerRawValue) ?? .apple
    }

    var body: some View {
        Group {
            if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        audioSection(item)
                        if item.hasRecording {
                            testSection(item)
                        } else {
                            noRecordingSection
                        }

                        if let summary = RecognitionComparisonSummary(item: item) {
                            comparisonSection(summary)
                        }

                        RecognitionResultSection(
                            mode: .withHotwords,
                            item: item
                        )

                        Divider()

                        RecognitionResultSection(
                            mode: .withoutHotwords,
                            item: item
                        )
                    }
                    .padding(20)
                }
            } else {
                ContentUnavailableView("识别历史不存在", systemImage: "clock.badge.xmark")
            }
        }
        .navigationTitle("识别历史")
        .navigationBarTitleDisplayMode(.inline)
        .alert("录音对照", isPresented: $showsAlert) {
            Button("好") {}
        } message: {
            Text(alertMessage)
        }
        .onDisappear {
            playback.stop()
        }
    }

    private func audioSection(_ item: RecognitionHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.createdAt.formatted(date: .long, time: .standard))
                .font(.headline)

            HStack(spacing: 12) {
                Label(HistoryFormatting.duration(item.duration), systemImage: "clock")
                Label(HistoryFormatting.fileSize(item.fileSize), systemImage: "internaldrive")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if item.hasRecording {
                Button {
                    do {
                        try playback.toggle(url: store.audioURL(for: item))
                    } catch {
                        alertMessage = "无法播放录音：\(error.localizedDescription)"
                        showsAlert = true
                    }
                } label: {
                    Label(
                        playback.isPlaying ? "停止播放" : "播放原音频",
                        systemImage: playback.isPlaying ? "stop.fill" : "play.fill"
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                }
                .buttonStyle(.bordered)
                .disabled(isRunning)
            } else {
                Label("此历史仅包含转写文本，未附原始录音", systemImage: "waveform.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var noRecordingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("重新转写")
                .font(.headline)
            Text("由于导入数据未包含原始录音，无法重新转写或运行热词对照。已有转写文本不受影响。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func testSection(_ item: RecognitionHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("热词对照")
                    .font(.headline)

                Spacer()

                let entries = HotwordLibraryStorage.loadEntries()
                Text(
                    "已激活 \(HotwordSelectionPolicy.select(from: entries).count)/" +
                    "\(HotwordSelectionPolicy.maximumActiveCount) · 总 \(entries.count)"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Label(
                "当前服务：\(selectedProvider.title)",
                systemImage: selectedProvider.systemImage
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Picker("识别模式", selection: $selectedMode) {
                ForEach(RecognitionHotwordMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isRunning)

            Button {
                runTranscriptions([selectedMode], item: item)
            } label: {
                Label("转写所选模式", systemImage: "waveform.badge.magnifyingglass")
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRunning || !selectedProviderIsReady)

            Button {
                runTranscriptions([.withHotwords, .withoutHotwords], item: item)
            } label: {
                Label("运行两组对照", systemImage: "arrow.left.arrow.right")
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .buttonStyle(.bordered)
            .disabled(isRunning || !selectedProviderIsReady)

            if isRunning {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(runningStatus)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if !selectedProviderIsReady {
                Text(selectedProviderUnavailableMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func comparisonSection(_ summary: RecognitionComparisonSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("对照摘要")
                .font(.headline)

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("文本相似度")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(summary.similarity.formatted(.percent.precision(.fractionLength(1))))
                        .font(.title3.monospacedDigit().weight(.semibold))
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text("热词文本命中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(summary.withHotwordsMatchCount) / \(summary.withoutHotwordsMatchCount)")
                        .font(.title3.monospacedDigit().weight(.semibold))
                }
            }

            Text(summary.isIdentical ? "两组转写完全相同" : "左侧为传入热词，右侧为不传热词")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var supportsSpeechAnalyzer: Bool {
        if #available(iOS 26.0, *) {
            return true
        }
        return false
    }

    private var selectedProviderIsReady: Bool {
        switch selectedProvider {
        case .apple:
            return supportsSpeechAnalyzer
        case .aliyun:
            return AliyunCredentialStore.hasAPIKey
        }
    }

    private var selectedProviderUnavailableMessage: String {
        switch selectedProvider {
        case .apple:
            return "Apple 录音对照需要 iOS 26 的 DictationTranscriber。"
        case .aliyun:
            return "请先在“识别服务”中保存阿里云百炼 API Key。"
        }
    }

    private func runTranscriptions(
        _ modes: [RecognitionHotwordMode],
        item: RecognitionHistoryItem
    ) {
        guard item.hasRecording else {
            alertMessage = "这条历史没有附带原始录音，无法重新转写。"
            showsAlert = true
            return
        }
        playback.stop()
        isRunning = true

        Task { @MainActor in
            defer {
                isRunning = false
                runningStatus = ""
            }

            let provider = selectedProvider
            let libraryEntries = HotwordLibraryStorage.loadEntries()
            let hotwords = libraryEntries.map(\.term)
            let activeHotwords = HotwordSelectionPolicy.selectedTerms(from: libraryEntries)
            var failures: [String] = []

            if provider == .apple {
                guard await SpeechPermissionRequester.requestSpeechRecognition() else {
                    alertMessage = "请在设置中允许语音识别权限。"
                    showsAlert = true
                    return
                }
                guard #available(iOS 26.0, *) else {
                    alertMessage = "当前系统不支持 DictationTranscriber。"
                    showsAlert = true
                    return
                }

                do {
                    runningStatus = "Apple · 准备中文识别模型"
                    let locale = try await AppleSpeechTranscriber.prepareLocale()
                    for (index, mode) in modes.enumerated() {
                        let contextTerms = mode == .withHotwords ? activeHotwords : []
                        runningStatus = "Apple · \(mode.title) · \(index + 1)/\(modes.count)"
                        do {
                            let appleOutput = try await AppleSpeechTranscriber.transcribe(
                                audioURL: store.audioURL(for: item),
                                locale: locale,
                                hotwords: contextTerms
                            )
                            let output = SpeechRecognitionServiceOutput(
                                transcript: appleOutput.transcript,
                                elapsed: appleOutput.elapsed,
                                words: [],
                                configuredHotwordCount: contextTerms.count,
                                ignoredHotwords: []
                            )
                            try save(
                                output: output,
                                provider: provider,
                                mode: mode,
                                item: item,
                                allHotwords: hotwords
                            )
                        } catch {
                            record(
                                error: error,
                                provider: provider,
                                mode: mode,
                                item: item,
                                failures: &failures
                            )
                        }
                    }
                } catch {
                    alertMessage = "无法准备 Apple 识别模型：\(error.localizedDescription)"
                    showsAlert = true
                    return
                }
            } else {
                for (index, mode) in modes.enumerated() {
                    let contextTerms = mode == .withHotwords ? activeHotwords : []
                    do {
                        let output = try await AliyunSpeechTranscriber.transcribe(
                            audioURL: store.audioURL(for: item),
                            hotwords: contextTerms
                        ) { progress in
                            runningStatus =
                                "\(progress) · \(mode.title) · \(index + 1)/\(modes.count)"
                        }
                        try save(
                            output: output,
                            provider: provider,
                            mode: mode,
                            item: item,
                            allHotwords: hotwords
                        )
                    } catch {
                        record(
                            error: error,
                            provider: provider,
                            mode: mode,
                            item: item,
                            failures: &failures
                        )
                    }
                }
            }

            if !failures.isEmpty {
                alertMessage = failures.joined(separator: "\n")
                showsAlert = true
            }
        }
    }

    private func save(
        output: SpeechRecognitionServiceOutput,
        provider: SpeechRecognitionProvider,
        mode: RecognitionHotwordMode,
        item: RecognitionHistoryItem,
        allHotwords: [String]
    ) throws {
        let transcript = SpeechTranscriptNormalizer.normalize(output.transcript)
        let matchedTerms = HotwordTranscriptMatcher.matches(
            in: transcript,
            hotwords: allHotwords
        )
        HotwordLibraryStorage.markTermsUsed(matchedTerms)
        try store.storeTranscription(
            itemID: item.id,
            mode: mode,
            transcript: transcript,
            elapsed: output.elapsed,
            configuredHotwordCount: output.configuredHotwordCount,
            matchedTerms: matchedTerms,
            provider: provider,
            words: output.words
        )
    }

    private func record(
        error: Error,
        provider: SpeechRecognitionProvider,
        mode: RecognitionHotwordMode,
        item: RecognitionHistoryItem,
        failures: inout [String]
    ) {
        let message = "\(provider.shortTitle) · \(mode.title)：\(error.localizedDescription)"
        store.storeFailure(
            itemID: item.id,
            mode: mode,
            provider: provider,
            message: message
        )
        failures.append(message)
    }
}

private struct RecognitionResultSection: View {
    let mode: RecognitionHotwordMode
    let item: RecognitionHistoryItem

    private var transcript: String? {
        item.transcript(for: mode)
    }

    private var matchedTerms: [String] {
        item.matchedTerms(for: mode)
    }

    private var words: [SpeechRecognitionWord] {
        item.words(for: mode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(mode.title)
                    .font(.headline)

                if let provider = item.provider(for: mode) {
                    Text(provider.shortTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let elapsed = item.elapsed(for: mode) {
                    Text(String(format: "%.2f 秒", elapsed))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let transcript {
                Text(transcript.isEmpty ? "未识别到文字" : transcript)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .textSelection(.enabled)

                HStack(spacing: 12) {
                    Label("命中 \(matchedTerms.count) 个热词", systemImage: "text.magnifyingglass")

                    if mode == .withHotwords,
                       let count = item.withHotwordsConfiguredCount {
                        Text("传入 \(count) 个")
                    }

                    if !words.isEmpty {
                        Text("\(words.count) 个字词时间戳")
                    }

                    Spacer()

                    Button {
                        UIPasteboard.general.string = transcript
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel("复制转写")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if !matchedTerms.isEmpty {
                    Text(matchedTerms.joined(separator: "、"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } else {
                Text("尚未运行")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if item.lastErrorMode == mode, let error = item.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

@MainActor
private final class RecognitionHistoryPlaybackController: ObservableObject {
    @Published private(set) var isPlaying = false

    private var player: AVAudioPlayer?
    private var stopTask: Task<Void, Never>?

    func toggle(url: URL) throws {
        if isPlaying {
            stop()
            return
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)

        let player = try AVAudioPlayer(contentsOf: url)
        player.prepareToPlay()
        guard player.play() else {
            throw RecognitionHistoryPlaybackError.cannotStart
        }

        self.player = player
        isPlaying = true

        stopTask?.cancel()
        stopTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(max(0.1, player.duration) * 1_000_000_000)
                )
            } catch {
                return
            }
            self?.stop()
        }
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        player?.stop()
        player = nil
        isPlaying = false
    }
}

private struct RecognitionComparisonSummary {
    let similarity: Double
    let isIdentical: Bool
    let withHotwordsMatchCount: Int
    let withoutHotwordsMatchCount: Int

    init?(item: RecognitionHistoryItem) {
        guard let withHotwords = item.transcriptWithHotwords,
              let withoutHotwords = item.transcriptWithoutHotwords else {
            return nil
        }

        let left = Self.normalizedCharacters(withHotwords)
        let right = Self.normalizedCharacters(withoutHotwords)
        let longestCount = max(left.count, right.count)
        let distance = Self.editDistance(left, right)

        similarity = longestCount == 0
            ? 1
            : max(0, 1 - Double(distance) / Double(longestCount))
        isIdentical = left == right
        withHotwordsMatchCount = item.matchedTerms(for: .withHotwords).count
        withoutHotwordsMatchCount = item.matchedTerms(for: .withoutHotwords).count
    }

    private static func normalizedCharacters(_ text: String) -> [Character] {
        let folded = HotwordLibraryStorage.comparisonKey(text)
        return folded.filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    private static func editDistance(_ left: [Character], _ right: [Character]) -> Int {
        guard !left.isEmpty else { return right.count }
        guard !right.isEmpty else { return left.count }

        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = Array(repeating: 0, count: right.count + 1)
            current[0] = leftIndex + 1

            for (rightIndex, rightCharacter) in right.enumerated() {
                let substitutionCost = leftCharacter == rightCharacter ? 0 : 1
                current[rightIndex + 1] = min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + substitutionCost
                )
            }
            previous = current
        }
        return previous[right.count]
    }
}

private enum HistoryFormatting {
    static func duration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private enum RecognitionHistoryPlaybackError: LocalizedError {
    case cannotStart

    var errorDescription: String? {
        "播放器无法启动。"
    }
}
