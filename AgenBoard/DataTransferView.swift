import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct DataTransferView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var historyStore: RecognitionHistoryStore
    @ObservedObject var hotwordStore: HotwordLibraryStore
    @ObservedObject var quickPhraseStore: QuickPhraseLibraryStore
    let onImported: () -> Void

    @State private var isExporting = false
    @State private var isPreparingImport = false
    @State private var isApplyingImport = false
    @State private var includeRecordings = false
    @State private var includeCredentials = false
    @State private var aliyunConfigured = false
    @State private var pinyinStatus = PinyinExportStatus.checking
    @State private var showsImporter = false
    @State private var exportArtifact: PortableExportArtifact?
    @State private var importPreview: PortableImportPreview?
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showsAlert = false

    private var isBusy: Bool {
        isExporting || isPreparingImport || isApplyingImport
    }

    private var availableRecordings: [RecognitionHistoryItem] {
        historyStore.items.filter(\.hasRecording)
    }

    private var recordingBytes: Int64 {
        availableRecordings.reduce(0) { partialResult, item in
            partialResult + max(0, item.fileSize)
        }
    }

    private var formattedRecordingBytes: String {
        ByteCountFormatter.string(fromByteCount: recordingBytes, countStyle: .file)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("开放、可读、可迁移", systemImage: "shippingbox")
                        .font(.headline)
                    Text(
                        "导出标准 ZIP，内部使用 UTF-8 JSON、JSONL、Markdown、Rime TSV 和可选 M4A。" +
                        "文件可以交给 AI 编辑，也可以导入其他 AgenBoard。"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                Button(action: createCompleteExport) {
                    HStack {
                        Label("一键导出用户数据", systemImage: "square.and.arrow.up")
                        Spacer()
                        if isExporting {
                            ProgressView()
                        }
                    }
                }
                .disabled(isBusy)

                Toggle("包含原始录音", isOn: $includeRecordings)
                    .disabled(isBusy || availableRecordings.isEmpty)

                if availableRecordings.isEmpty {
                    Text("当前没有可导出的原始录音，转写文本仍会正常导出。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if includeRecordings {
                    Label(
                        "将包含 \(availableRecordings.count) 个 M4A 录音，" +
                        "预计增加 \(formattedRecordingBytes)。",
                        systemImage: "waveform"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else {
                    Text(
                        "默认只导出转写文本；\(availableRecordings.count) 个原始录音" +
                        "（约 \(formattedRecordingBytes)）不会包含。"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Toggle("包含阿里云 API Key", isOn: $includeCredentials)
                    .disabled(isBusy || !aliyunConfigured)

                if includeCredentials {
                    Label(
                        "API Key 将以明文写入 credentials.json，便于完整迁移。",
                        systemImage: "exclamationmark.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else if !aliyunConfigured {
                    Text("当前没有已保存的阿里云 API Key。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("热词", value: "\(hotwordStore.entries.count) 个")
                LabeledContent("快捷短语", value: "\(quickPhraseStore.phrases.count) 条")
                LabeledContent("识别历史", value: "\(historyStore.items.count) 条")
                LabeledContent(
                    "拼音学习",
                    value: pinyinStatus.summary
                )
                if let detail = pinyinStatus.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("导出")
            } footer: {
                Text(
                    "转写文本和可用的拼音学习快照始终导出，原始录音和 API Key 仅在你明确开启时导出；" +
                    "钥匙串本身、缓存、临时文件、画中画和键盘运行状态不会导出。"
                )
            }

            Section {
                Button {
                    showsImporter = true
                } label: {
                    HStack {
                        Label("选择 AgenBoard ZIP", systemImage: "square.and.arrow.down")
                        Spacer()
                        if isPreparingImport {
                            ProgressView()
                        }
                    }
                }
                .disabled(isBusy)
            } header: {
                Text("导入")
            } footer: {
                Text("导入前会先校验并展示预览。默认智能合并，也可以选择完全替换。")
            }

            Section("数据格式") {
                DataFormatRow(
                    name: "README.md",
                    detail: "给用户和 AI 的内容说明与字段文档"
                )
                DataFormatRow(
                    name: "hotwords.json",
                    detail: "热词、启用、置顶与最近使用时间"
                )
                DataFormatRow(
                    name: "quick-phrases.json",
                    detail: "快捷短语、顺序与启用状态"
                )
                DataFormatRow(
                    name: "credentials.json（可选）",
                    detail: "仅在用户明确开启时包含明文阿里云 API Key"
                )
                DataFormatRow(
                    name: "recognition-history.jsonl",
                    detail: "一行一条识别历史，适合 AI 流式处理"
                )
                DataFormatRow(
                    name: "pinyin/rime_ice.userdb.txt",
                    detail: "Rime 可读文本快照：拼音、候选、使用次数、权重和时间"
                )
                DataFormatRow(
                    name: "recordings/（可选）",
                    detail: "仅在用户明确开启时包含标准 M4A 原始录音"
                )
            }
        }
        .navigationTitle("导入与导出")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refreshExportMetadata()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else {
                return
            }
            Task {
                await refreshExportMetadata()
            }
        }
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false,
            onCompletion: handleSelectedImport
        )
        .sheet(item: $exportArtifact) { artifact in
            PortableActivityView(
                url: artifact.url,
                onComplete: {
                    PortableDataService.shared.discardExport(at: artifact.url)
                    exportArtifact = nil
                }
            )
        }
        .sheet(item: $importPreview) { preview in
            PortableImportPreviewView(
                preview: preview,
                isApplying: isApplyingImport,
                onApply: { mode in
                    applyImport(preview, mode: mode)
                },
                onCancel: {
                    PortableDataService.shared.discardImport(preview)
                    importPreview = nil
                }
            )
        }
        .alert(alertTitle, isPresented: $showsAlert) {
            Button("好") {}
        } message: {
            Text(alertMessage)
        }
    }

    private func refreshExportMetadata() async {
        async let configured = Task.detached(priority: .utility) {
            AliyunCredentialStore.hasAPIKey
        }.value
        async let learnedEntries = Task.detached(priority: .utility) {
            do {
                guard let snapshot = try SharedPinyinUserDataStore.latestSnapshot() else {
                    if let verification = SharedCommandStore
                        .latestKeyboardAccessVerification(),
                       !verification.isVerified {
                        return PinyinExportStatus.unavailable(
                            "键盘尚未通过完全访问验证；私有学习数据会在允许完全访问并再次打开键盘后迁移到可导出的共享快照。"
                        )
                    }
                    return PinyinExportStatus.empty
                }
                return PinyinExportStatus.ready(snapshot.entryCount)
            } catch {
                return PinyinExportStatus.unavailable(error.localizedDescription)
            }
        }.value
        aliyunConfigured = await configured
        pinyinStatus = await learnedEntries
    }

    private func createCompleteExport() {
        guard !isBusy else {
            return
        }
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                let url = try await PortableDataService.shared.createCompleteExport(
                    historyStore: historyStore,
                    hotwordStore: hotwordStore,
                    quickPhraseStore: quickPhraseStore,
                    includeRecordings: includeRecordings,
                    includeCredentials: includeCredentials
                )
                exportArtifact = PortableExportArtifact(url: url)
            } catch {
                showError(title: "导出失败", error: error)
            }
        }
    }

    private func handleSelectedImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else {
                return
            }
            isPreparingImport = true
            Task {
                defer { isPreparingImport = false }
                do {
                    importPreview = try await PortableDataService.shared.prepareImport(
                        from: url,
                        historyStore: historyStore,
                        hotwordStore: hotwordStore,
                        quickPhraseStore: quickPhraseStore
                    )
                } catch {
                    showError(title: "无法导入", error: error)
                }
            }
        } catch {
            showError(title: "无法读取文件", error: error)
        }
    }

    private func applyImport(
        _ preview: PortableImportPreview,
        mode: PortableImportMode
    ) {
        guard !isApplyingImport else {
            return
        }
        isApplyingImport = true

        Task { @MainActor in
            defer { isApplyingImport = false }
            do {
                let result = try PortableDataService.shared.applyImport(
                    preview,
                    mode: mode,
                    historyStore: historyStore,
                    hotwordStore: hotwordStore,
                    quickPhraseStore: quickPhraseStore
                )
                importPreview = nil
                onImported()
                alertTitle = "导入完成"
                alertMessage =
                    "已\(result.mode.title)：热词 \(result.hotwordCount) 个、" +
                    "快捷短语 \(result.quickPhraseCount) 条、" +
                    "识别历史 \(result.historyCount) 条。" +
                    (result.pinyinEntryCount.map {
                        " 拼音学习 \($0) 条将在下次打开键盘时恢复。"
                    } ?? "")
                showsAlert = true
            } catch {
                showError(title: "导入失败", error: error)
            }
        }
    }

    private func showError(title: String, error: Error) {
        alertTitle = title
        alertMessage = error.localizedDescription
        showsAlert = true
    }
}

private enum PinyinExportStatus: Sendable {
    case checking
    case empty
    case ready(Int)
    case unavailable(String)

    var summary: String {
        switch self {
        case .checking:
            return "检查中…"
        case .empty:
            return "暂无学习记录"
        case let .ready(count):
            return "\(count) 条"
        case .unavailable:
            return "快照待更新"
        }
    }

    var detail: String? {
        guard case let .unavailable(message) = self else {
            return nil
        }
        return message
    }
}

private struct DataFormatRow: View {
    let name: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name)
                .font(.subheadline.monospaced())
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct PortableImportPreviewView: View {
    let preview: PortableImportPreview
    let isApplying: Bool
    let onApply: (PortableImportMode) -> Void
    let onCancel: () -> Void

    @State private var showsReplaceConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                Section("数据包") {
                    LabeledContent("文件", value: preview.fileName)
                    LabeledContent("来源版本", value: preview.appVersion)
                    LabeledContent(
                        "导出时间",
                        value: preview.exportedAt.formatted(date: .abbreviated, time: .shortened)
                    )
                }

                Section("包含内容") {
                    ImportCountRow(
                        title: "用户偏好",
                        systemImage: "gearshape",
                        count: 1
                    )
                    ImportCountRow(
                        title: "热词",
                        systemImage: "text.book.closed",
                        count: preview.counts.hotwords
                    )
                    ImportCountRow(
                        title: "快捷短语",
                        systemImage: "rectangle.grid.2x2",
                        count: preview.counts.quickPhrases
                    )
                    ImportCountRow(
                        title: "识别历史",
                        systemImage: "clock.arrow.circlepath",
                        count: preview.counts.recognitionHistory
                    )
                    ImportCountRow(
                        title: "录音",
                        systemImage: "waveform",
                        count: preview.counts.recordings
                    )
                    if preview.pinyinIncluded {
                        ImportCountRow(
                            title: "拼音学习记录",
                            systemImage: "character.book.closed",
                            count: preview.counts.pinyinEntries
                        )
                    }
                    if preview.credentialsIncluded {
                        ImportCountRow(
                            title: "阿里云 API Key",
                            systemImage: "key",
                            count: 1
                        )
                    }
                }

                Section("智能合并预览") {
                    LabeledContent("识别与键盘偏好", value: "使用导入值")
                    if preview.pinyinIncluded {
                        LabeledContent(
                            "拼音学习记录",
                            value: "由 Rime 原生合并"
                        )
                    }
                    MergePreviewRow(
                        title: "热词",
                        added: preview.mergeSummary.newHotwords,
                        updated: preview.mergeSummary.updatedHotwords,
                        duplicates: preview.mergeSummary.duplicateHotwords
                    )
                    MergePreviewRow(
                        title: "快捷短语",
                        added: preview.mergeSummary.newQuickPhrases,
                        updated: preview.mergeSummary.updatedQuickPhrases,
                        duplicates: preview.mergeSummary.duplicateQuickPhrases
                    )
                    LabeledContent("新增历史", value: "\(preview.mergeSummary.newHistoryItems) 条")
                    LabeledContent(
                        "合并已有历史",
                        value: "\(preview.mergeSummary.existingHistoryItems) 条"
                    )
                }

                if !preview.warnings.isEmpty {
                    Section("提示") {
                        ForEach(preview.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section {
                    Button {
                        onApply(.merge)
                    } label: {
                        HStack {
                            Label("智能合并", systemImage: "arrow.triangle.merge")
                            Spacer()
                            if isApplying {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isApplying)

                    Button(role: .destructive) {
                        showsReplaceConfirmation = true
                    } label: {
                        Label("完全替换当前数据", systemImage: "arrow.clockwise")
                    }
                    .disabled(isApplying)
                } footer: {
                    Text(
                        "智能合并会用稳定 ID 更新同一条数据，并保留当前设备独有内容；" +
                        "完全替换会以导入包覆盖当前热词、短语、偏好、历史、包内录音" +
                        (preview.pinyinIncluded ? "和拼音学习记录。" : "。")
                    )
                }
            }
            .navigationTitle("导入预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                        .disabled(isApplying)
                }
            }
            .interactiveDismissDisabled()
            .confirmationDialog(
                "用导入包完全替换当前用户数据？",
                isPresented: $showsReplaceConfirmation,
                titleVisibility: .visible
            ) {
                Button("完全替换", role: .destructive) {
                    onApply(.replace)
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(
                    "当前热词、快捷短语、识别历史和原始录音将按导入包内容替换。" +
                    (preview.pinyinIncluded
                        ? " 拼音学习记录将在下次打开键盘时替换。"
                        : " 当前拼音学习记录会保留。")
                )
            }
        }
    }
}

private struct ImportCountRow: View {
    let title: String
    let systemImage: String
    let count: Int

    var body: some View {
        LabeledContent {
            Text("\(count)")
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}

private struct MergePreviewRow: View {
    let title: String
    let added: Int
    let updated: Int
    let duplicates: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Text("新增 \(added) · 更新 \(updated) · 跳过重复 \(duplicates)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PortableExportArtifact: Identifiable {
    let id = UUID()
    let url: URL
}

private struct PortableActivityView: UIViewControllerRepresentable {
    let url: URL
    let onComplete: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [url],
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in
                onComplete()
            }
        }
        return controller
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}
