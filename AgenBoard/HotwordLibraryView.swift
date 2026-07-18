import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class HotwordLibraryStore: ObservableObject {
    @Published private(set) var entries: [HotwordEntry]

    init(loadImmediately: Bool = true) {
        entries = loadImmediately ? HotwordLibraryStorage.loadEntries() : []
    }

    var activeEntries: [HotwordEntry] {
        HotwordSelectionPolicy.select(from: entries)
    }

    var activeCount: Int {
        activeEntries.count
    }

    @discardableResult
    func add(_ candidates: [String]) -> HotwordImportReport {
        var keys = Set(entries.map { HotwordLibraryStorage.comparisonKey($0.term) })
        var addedCount = 0
        var duplicateCount = 0
        var invalidCount = 0

        for candidate in candidates {
            guard let term = HotwordLibraryStorage.normalizedTerm(candidate) else {
                invalidCount += 1
                continue
            }

            if keys.insert(HotwordLibraryStorage.comparisonKey(term)).inserted {
                entries.append(HotwordEntry(term: term))
                addedCount += 1
            } else {
                duplicateCount += 1
            }
        }

        if addedCount > 0 {
            HotwordLibraryStorage.save(entries)
        }
        return HotwordImportReport(
            addedCount: addedCount,
            duplicateCount: duplicateCount,
            invalidCount: invalidCount
        )
    }

    func remove(ids: [UUID]) {
        let removedIDs = Set(ids)
        entries.removeAll { removedIDs.contains($0.id) }
        HotwordLibraryStorage.save(entries)
    }

    func togglePinned(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return
        }
        entries[index].isPinned.toggle()
        HotwordLibraryStorage.save(entries)
    }

    func setEnabled(_ isEnabled: Bool, id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return
        }
        entries[index].isEnabled = isEnabled
        HotwordLibraryStorage.save(entries)
    }

    func refresh() {
        entries = HotwordLibraryStorage.loadEntries()
    }

    func removeAll() {
        entries = []
        HotwordLibraryStorage.save(entries)
    }
}

struct HotwordLibraryView: View {
    @ObservedObject var store: HotwordLibraryStore

    @State private var draftTerm = ""
    @State private var searchText = ""
    @State private var additionMessage = ""
    @State private var isImporting = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showsAlert = false
    @State private var showsClearConfirmation = false
    @FocusState private var isDraftFocused: Bool

    private var displayedEntries: [DisplayedHotword] {
        let enabled = HotwordSelectionPolicy.rankedEnabledEntries(from: store.entries)
        let disabled = store.entries.filter { !$0.isEnabled }
        let activeIDs = Set(store.activeEntries.map(\.id))

        return (enabled + disabled).compactMap { entry in
            guard searchText.isEmpty || entry.term.localizedCaseInsensitiveContains(searchText) else {
                return nil
            }
            return DisplayedHotword(entry: entry, isActive: activeIDs.contains(entry.id))
        }
    }

    var body: some View {
        List {
            Section("添加热词") {
                HStack(spacing: 12) {
                    TextField("输入一个热词", text: $draftTerm)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isDraftFocused)
                        .submitLabel(.done)
                        .onSubmit(addDraftTerm)

                    Button(action: addDraftTerm) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                    .disabled(
                        draftTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .accessibilityLabel("添加热词")
                }

                if !additionMessage.isEmpty {
                    Text(additionMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("导入") {
                Button {
                    isImporting = true
                } label: {
                    Label("导入文本词库", systemImage: "square.and.arrow.down")
                }

                Button(role: .destructive) {
                    showsClearConfirmation = true
                } label: {
                    Label("清空词库", systemImage: "trash")
                }
                .disabled(store.entries.isEmpty)
            }

            Section {
                if displayedEntries.isEmpty {
                    Text(searchText.isEmpty ? "还没有热词" : "没有匹配的热词")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(displayedEntries) { item in
                        HStack(spacing: 12) {
                            Button {
                                store.togglePinned(id: item.id)
                            } label: {
                                Image(systemName: item.entry.isPinned ? "pin.fill" : "pin")
                                    .frame(width: 24, height: 30)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(item.entry.isPinned ? Color.accentColor : Color.secondary)
                            .accessibilityLabel(item.entry.isPinned ? "取消置顶" : "置顶")

                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.entry.term)
                                    .foregroundStyle(item.entry.isEnabled ? Color.primary : Color.secondary)

                                Text(item.statusText)
                                    .font(.caption)
                                    .foregroundStyle(item.isActive ? Color.accentColor : Color.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Toggle(
                                "启用 \(item.entry.term)",
                                isOn: Binding(
                                    get: { item.entry.isEnabled },
                                    set: { store.setEnabled($0, id: item.id) }
                                )
                            )
                            .labelsHidden()
                        }
                    }
                    .onDelete(perform: deleteDisplayedEntries)
                }
            } header: {
                HStack {
                    Text("全部热词")
                    Spacer()
                    Text(
                        "已激活 \(store.activeCount)/\(HotwordSelectionPolicy.maximumActiveCount)、" +
                        "总词数 \(store.entries.count)"
                    )
                }
            } footer: {
                Text("每次识别最多激活 100 个词。已启用的置顶词优先，其余按最近命中时间补齐。")
            }
        }
        .navigationTitle("热词词库")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
        .toolbar {
            if !displayedEntries.isEmpty {
                EditButton()
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.plainText],
            allowsMultipleSelection: false,
            onCompletion: importFiles
        )
        .alert(alertTitle, isPresented: $showsAlert) {
            Button("好") {}
        } message: {
            Text(alertMessage)
        }
        .confirmationDialog(
            "清空全部 \(store.entries.count) 个热词？",
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空词库", role: .destructive) {
                store.removeAll()
                additionMessage = "词库已清空"
            }
            Button("取消", role: .cancel) {}
        }
        .onAppear {
            store.refresh()
        }
    }

    private func addDraftTerm() {
        let report = store.add([draftTerm])
        if report.addedCount == 1 {
            additionMessage = "已添加 \(draftTerm.trimmingCharacters(in: .whitespacesAndNewlines))"
            draftTerm = ""
            isDraftFocused = true
        } else if report.duplicateCount == 1 {
            additionMessage = "这个热词已经存在"
        } else {
            additionMessage = "热词不能为空且不能超过 128 个字符"
        }
    }

    private func deleteDisplayedEntries(at offsets: IndexSet) {
        let removedIDs = offsets.map { displayedEntries[$0].id }
        store.remove(ids: removedIDs)
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else {
                return
            }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let data = try Data(contentsOf: url)
            guard let text = decodeText(data) else {
                throw HotwordImportError.unsupportedEncoding
            }
            let candidates = HotwordLibraryStorage.parseTerms(from: text)
            guard !candidates.isEmpty else {
                throw HotwordImportError.emptyFile
            }

            let report = store.add(candidates)
            alertTitle = "导入完成"
            alertMessage =
                "新增 \(report.addedCount) 个，跳过重复 \(report.duplicateCount) 个" +
                (report.invalidCount > 0 ? "，忽略无效 \(report.invalidCount) 个" : "") +
                "。当前共 \(store.entries.count) 个热词。"
            showsAlert = true
        } catch {
            alertTitle = "导入失败"
            alertMessage = error.localizedDescription
            showsAlert = true
        }
    }

    private func decodeText(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .utf16LittleEndian)
            ?? String(data: data, encoding: .utf16BigEndian)
    }
}

private struct DisplayedHotword: Identifiable {
    let entry: HotwordEntry
    let isActive: Bool

    var id: UUID { entry.id }

    var statusText: String {
        if !entry.isEnabled {
            return "已停用"
        }
        return isActive ? "已激活" : "候补"
    }
}

private enum HotwordImportError: LocalizedError {
    case emptyFile
    case unsupportedEncoding

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "文件中没有可导入的热词。"
        case .unsupportedEncoding:
            return "无法读取文件编码，请使用 UTF-8 或 UTF-16 文本文件。"
        }
    }
}

#Preview {
    NavigationStack {
        HotwordLibraryView(store: HotwordLibraryStore())
    }
}
