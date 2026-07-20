import SwiftUI

enum QuickPhraseSaveResult: Equatable {
    case saved
    case invalid
    case duplicate
}

@MainActor
final class QuickPhraseLibraryStore: ObservableObject {
    @Published private(set) var phrases: [SharedQuickPhrase]

    init(loadImmediately: Bool = true) {
        phrases = loadImmediately ? SharedCommandStore.quickPhrases() : []
    }

    var enabledCount: Int {
        phrases.filter(\.isEnabled).count
    }

    @discardableResult
    func add(title: String, content: String) -> QuickPhraseSaveResult {
        guard let normalized = normalizedValues(title: title, content: content) else {
            return .invalid
        }
        guard !containsDuplicate(content: normalized.content) else {
            return .duplicate
        }

        phrases.append(
            SharedQuickPhrase(
                title: normalized.title,
                content: normalized.content,
                isEnabled: enabledCount < SharedCommandStore.maximumKeyboardQuickPhraseCount
            )
        )
        save()
        return .saved
    }

    @discardableResult
    func update(
        id: UUID,
        title: String,
        content: String
    ) -> QuickPhraseSaveResult {
        guard let index = phrases.firstIndex(where: { $0.id == id }),
              let normalized = normalizedValues(title: title, content: content) else {
            return .invalid
        }
        guard !containsDuplicate(content: normalized.content, excluding: id) else {
            return .duplicate
        }

        phrases[index].title = normalized.title
        phrases[index].content = normalized.content
        save()
        return .saved
    }

    @discardableResult
    func setEnabled(_ isEnabled: Bool, id: UUID) -> Bool {
        guard let index = phrases.firstIndex(where: { $0.id == id }) else {
            return false
        }
        if isEnabled,
           !phrases[index].isEnabled,
           enabledCount >= SharedCommandStore.maximumKeyboardQuickPhraseCount {
            return false
        }

        phrases[index].isEnabled = isEnabled
        save()
        return true
    }

    func remove(at offsets: IndexSet) {
        phrases.remove(atOffsets: offsets)
        save()
    }

    func move(from offsets: IndexSet, to destination: Int) {
        phrases.move(fromOffsets: offsets, toOffset: destination)
        save()
    }

    func resetToDefaults() {
        phrases = SharedCommandStore.defaultQuickPhrases
        save()
    }

    func refresh() {
        phrases = SharedCommandStore.quickPhrases()
    }

    private func save() {
        SharedCommandStore.saveQuickPhrases(phrases)
    }

    private func normalizedValues(
        title: String,
        content: String
    ) -> (title: String, content: String)? {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty,
              !normalizedContent.isEmpty,
              normalizedTitle.count <= 64,
              normalizedContent.count <= 500 else {
            return nil
        }
        return (normalizedTitle, normalizedContent)
    }

    private func containsDuplicate(content: String, excluding id: UUID? = nil) -> Bool {
        phrases.contains { phrase in
            phrase.id != id
                && phrase.content.compare(
                    content,
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
                ) == .orderedSame
        }
    }
}

struct QuickPhraseLibraryView: View {
    @ObservedObject var store: QuickPhraseLibraryStore

    @State private var draftTitle = ""
    @State private var draftContent = ""
    @State private var statusMessage = ""
    @State private var editingPhrase: SharedQuickPhrase?
    @State private var showsResetConfirmation = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case title
        case content
    }

    var body: some View {
        List {
            Section("添加快捷短语") {
                TextField("按钮名称，例如：新建会话", text: $draftTitle)
                    .focused($focusedField, equals: .title)
                    .textInputAutocapitalization(.never)

                TextField("点击后插入的文字或指令", text: $draftContent, axis: .vertical)
                    .focused($focusedField, equals: .content)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(2...5)

                Button(action: addDraft) {
                    Label("添加到短语库", systemImage: "plus.circle.fill")
                }
                .disabled(
                    draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || draftContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if store.phrases.isEmpty {
                    Text("短语库是空的")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.phrases) { phrase in
                        HStack(spacing: 12) {
                            Button {
                                editingPhrase = phrase
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(phrase.title)
                                        .foregroundStyle(.primary)

                                    Text(phrase.content)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Toggle(
                                "在键盘显示 \(phrase.title)",
                                isOn: Binding(
                                    get: { phrase.isEnabled },
                                    set: { isEnabled in
                                        if !store.setEnabled(isEnabled, id: phrase.id) {
                                            statusMessage =
                                                "键盘最多显示 \(SharedCommandStore.maximumKeyboardQuickPhraseCount) 条短语"
                                        }
                                    }
                                )
                            )
                            .labelsHidden()
                        }
                    }
                    .onDelete(perform: store.remove)
                    .onMove(perform: store.move)
                }
            } header: {
                HStack {
                    Text("全部短语")
                    Spacer()
                    Text(
                        "键盘 \(store.enabledCount)/" +
                        "\(SharedCommandStore.maximumKeyboardQuickPhraseCount)"
                    )
                }
            } footer: {
                Text("打开开关的短语会按这里的顺序显示在键盘中。点击短语可以编辑，拖动可以排序。")
            }

            Section {
                Button(role: .destructive) {
                    showsResetConfirmation = true
                } label: {
                    Label("恢复默认短语", systemImage: "arrow.counterclockwise")
                }
            }
        }
        .navigationTitle("快捷短语库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !store.phrases.isEmpty {
                EditButton()
            }
        }
        .sheet(item: $editingPhrase) { phrase in
            QuickPhraseEditorView(phrase: phrase) { title, content in
                let result = store.update(id: phrase.id, title: title, content: content)
                if result == .saved {
                    statusMessage = "已更新 \(title)"
                }
                return result
            }
        }
        .confirmationDialog(
            "恢复内置的“你好”和“稍后回复”两条示例短语？",
            isPresented: $showsResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("恢复默认短语", role: .destructive) {
                store.resetToDefaults()
                statusMessage = "已恢复默认短语"
            }
            Button("取消", role: .cancel) {}
        }
        .onAppear {
            store.refresh()
        }
    }

    private func addDraft() {
        let keyboardWasFull =
            store.enabledCount >= SharedCommandStore.maximumKeyboardQuickPhraseCount

        switch store.add(title: draftTitle, content: draftContent) {
        case .saved:
            statusMessage =
                keyboardWasFull
                    ? "已添加；键盘名额已满，可在下方选择要显示的短语"
                    : "已添加到键盘"
            draftTitle = ""
            draftContent = ""
            focusedField = .title
        case .invalid:
            statusMessage = "名称和内容不能为空；名称最多 64 字，内容最多 500 字"
        case .duplicate:
            statusMessage = "相同内容已经存在"
        }
    }
}

private struct QuickPhraseEditorView: View {
    let phrase: SharedQuickPhrase
    let onSave: (String, String) -> QuickPhraseSaveResult

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var content: String
    @State private var errorMessage = ""

    init(
        phrase: SharedQuickPhrase,
        onSave: @escaping (String, String) -> QuickPhraseSaveResult
    ) {
        self.phrase = phrase
        self.onSave = onSave
        _title = State(initialValue: phrase.title)
        _content = State(initialValue: phrase.content)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("按钮名称") {
                    TextField("名称", text: $title)
                        .textInputAutocapitalization(.never)
                }

                Section("插入内容") {
                    TextField("文字或指令", text: $content, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(3...8)
                }

                if !errorMessage.isEmpty {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("编辑快捷短语")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                    }
                }
            }
        }
    }

    private func save() {
        switch onSave(title, content) {
        case .saved:
            dismiss()
        case .invalid:
            errorMessage = "名称和内容不能为空；名称最多 64 字，内容最多 500 字"
        case .duplicate:
            errorMessage = "相同内容已经存在"
        }
    }
}
