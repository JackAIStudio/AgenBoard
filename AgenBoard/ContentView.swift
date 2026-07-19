import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var recorder: SpeechRecorder
    @StateObject private var historyStore: RecognitionHistoryStore
    @StateObject private var pip = PictureInPictureCoordinator()
    @StateObject private var hotwordStore = HotwordLibraryStore(loadImmediately: false)
    @StateObject private var quickPhraseStore = QuickPhraseLibraryStore(loadImmediately: false)
    @StateObject private var recordingRequestObserver = SharedRecordingRequestObserver()
    @AppStorage(
        RecognitionPreferences.useHotwordsKey,
        store: RecognitionPreferences.defaults
    ) private var usesHotwords = true
    @AppStorage(
        SpeechServicePreferences.providerKey,
        store: SpeechServicePreferences.defaults
    ) private var providerRawValue = SpeechRecognitionProvider.apple.rawValue
    @State private var aliyunConfigured = false
    @State private var handledRecordingRequestIDs: Set<String> = []
    @State private var deferredRecordingRequestID: String?
    @State private var activeLaunchRequest: SharedRecordingToggleRequest?
    @State private var showsManualReturnGuidance = false
    @State private var showsQuickPhraseLibrary = false
    @State private var keyboardQuickPhraseModuleVisible =
        SharedCommandStore.keyboardQuickPhraseModuleVisible()
    @State private var keyboardHapticsEnabled = SharedCommandStore.keyboardHapticsEnabled()

    private let recordingRequestLifetime: TimeInterval = 15

    private var selectedProvider: SpeechRecognitionProvider {
        SpeechRecognitionProvider(rawValue: providerRawValue) ?? .apple
    }

    private var selectedProviderIsReady: Bool {
        selectedProvider == .apple || aliyunConfigured
    }

    init() {
        RecordingLaunchMetrics.mark("main_content_init_started")
        let historyStore = RecognitionHistoryStore()
        _historyStore = StateObject(wrappedValue: historyStore)
        _recorder = StateObject(wrappedValue: SpeechRecorder(historyStore: historyStore))
        RecordingLaunchMetrics.mark("main_content_init_finished")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("AgenBoard")
                            .font(.largeTitle.bold())

                        Text(recorder.status)
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        if showsManualReturnGuidance {
                            Label {
                                Text(
                                    recorder.isRecording
                                        ? "录音已启动，请点屏幕左上角的系统返回入口，回到刚才的 App。"
                                        : "正在准备录音；启动后请点屏幕左上角的系统返回入口。"
                                )
                            } icon: {
                                Image(systemName: "arrow.backward.circle.fill")
                            }
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.blue)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.blue.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }

                    NavigationLink {
                        SpeechServiceSettingsView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedProvider.systemImage)
                                .font(.title3)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("识别服务")
                                    .font(.headline)

                                Text(
                                    selectedProvider == .aliyun && !aliyunConfigured
                                        ? "阿里云 Fun-ASR · 需要配置 API Key"
                                        : selectedProvider.title
                                )
                                    .font(.caption)
                                    .foregroundStyle(
                                        selectedProviderIsReady
                                            ? Color.secondary
                                            : Color.orange
                                    )
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(recorder.isRecording || recorder.isTranscribing)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    Toggle(isOn: $usesHotwords) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("识别热词")
                                .font(.headline)

                            Text(
                                usesHotwords
                                    ? "已激活 \(hotwordStore.activeCount)/\(HotwordSelectionPolicy.maximumActiveCount) · 总词数 \(hotwordStore.entries.count)"
                                    : "已关闭 · 总词数 \(hotwordStore.entries.count)"
                            )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(recorder.isRecording || recorder.isTranscribing)
                    .padding(14)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    Button {
                        recorder.toggleRecording()
                    } label: {
                        Label(recorder.buttonTitle, systemImage: recorder.buttonIcon)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(recorder.isTranscribing || !selectedProviderIsReady)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("录音输入")
                                .font(.headline)

                            Spacer()

                            Text(recorder.audioDebugText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        AudioLevelMeter(level: recorder.audioLevel, isActive: recorder.isRecording)

                        HStack {
                            Button {
                                recorder.togglePlayback()
                            } label: {
                                Label(recorder.playbackButtonTitle, systemImage: recorder.playbackButtonIcon)
                            }
                            .disabled(!recorder.canPlayRecording || recorder.isRecording)

                            Spacer()

                            Text(recorder.recordingInfoText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    NavigationLink {
                        RecognitionHistoryListView(store: historyStore)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.title3)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("识别历史")
                                    .font(.headline)

                                Text("\(historyStore.items.count) 条历史")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    NavigationLink {
                        HotwordLibraryView(store: hotwordStore)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "text.book.closed")
                                .font(.title3)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("热词词库")
                                    .font(.headline)

                                Text(
                                    "已激活 \(hotwordStore.activeCount)/\(HotwordSelectionPolicy.maximumActiveCount) · " +
                                    "总词数 \(hotwordStore.entries.count)"
                                )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    NavigationLink {
                        QuickPhraseLibraryView(store: quickPhraseStore)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "rectangle.grid.2x2")
                                .font(.title3)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("快捷短语库")
                                    .font(.headline)

                                Text(
                                    "键盘显示 \(quickPhraseStore.enabledCount)/" +
                                    "\(SharedCommandStore.maximumKeyboardQuickPhraseCount) · " +
                                    "总短语 \(quickPhraseStore.phrases.count)"
                                )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    NavigationLink {
                        DataTransferView(
                            historyStore: historyStore,
                            hotwordStore: hotwordStore,
                            quickPhraseStore: quickPhraseStore,
                            onImported: refreshImportedPortableData
                        )
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.up.arrow.down.square")
                                .font(.title3)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("导入与导出")
                                    .font(.headline)

                                Text("开放 ZIP · AI 易读 · 可迁移")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(recorder.isRecording || recorder.isTranscribing)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    Toggle(
                        isOn: Binding(
                            get: { keyboardQuickPhraseModuleVisible },
                            set: { isVisible in
                                keyboardQuickPhraseModuleVisible = isVisible
                                SharedCommandStore.setKeyboardQuickPhraseModuleVisible(isVisible)
                            }
                        )
                    ) {
                        HStack(spacing: 12) {
                            Image(systemName: "text.quote")
                                .font(.title3)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("显示快捷短语模块")
                                    .font(.headline)

                                Text(
                                    keyboardQuickPhraseModuleVisible
                                        ? "键盘顶部显示快捷短语入口"
                                        : "键盘顶部仅显示语音和键盘入口"
                                )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                    .padding(14)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    Toggle(
                        isOn: Binding(
                            get: { keyboardHapticsEnabled },
                            set: { isEnabled in
                                keyboardHapticsEnabled = isEnabled
                                SharedCommandStore.setKeyboardHapticsEnabled(isEnabled)
                            }
                        )
                    ) {
                        HStack(spacing: 12) {
                            Image(systemName: "iphone.radiowaves.left.and.right")
                                .font(.title3)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("键盘触感反馈")
                                    .font(.headline)

                                Text(keyboardHapticsEnabled ? "按键时提供轻触反馈" : "已关闭")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                    .padding(14)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("画中画测试")
                                    .font(.headline)

                                Text(pip.status)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button {
                                pip.toggle()
                            } label: {
                                Label(pip.buttonTitle, systemImage: pip.buttonIcon)
                            }
                            .buttonStyle(.bordered)
                        }

                        PictureInPictureSourceView(coordinator: pip)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(.quaternary)
                            }
                    }
                    .padding(14)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("识别结果")
                                .font(.headline)

                            Spacer()

                            if recorder.isTranscribing {
                                ProgressView()
                            }
                        }

                        TextEditor(text: $recorder.transcript)
                            .font(.body)
                            .frame(minHeight: 220)
                            .padding(10)
                            .background(.background)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(.quaternary)
                            }
                    }

                    HStack {
                        Button {
                            UIPasteboard.general.string = recorder.transcript
                            recorder.status = "已复制"
                        } label: {
                            Label("复制", systemImage: "doc.on.doc")
                        }
                        .disabled(recorder.transcript.isEmpty)

                        Spacer()

                        Button(role: .destructive) {
                            recorder.clear()
                        } label: {
                            Label("清空", systemImage: "trash")
                        }
                        .disabled(recorder.transcript.isEmpty && !recorder.isRecording)
                    }
                }
                .padding(20)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showsQuickPhraseLibrary) {
                QuickPhraseLibraryView(store: quickPhraseStore)
            }
        }
        .alert("AgenBoard", isPresented: $recorder.showsError) {
            Button("好") {}
        } message: {
            Text(recorder.errorMessage)
        }
        .onAppear {
            configurePictureInPictureActions()
        }
        .onChange(of: recorder.isRecording) { _, isRecording in
            pip.setRecordingState(isRecording)
            if isRecording {
                RecordingLaunchMetrics.mark(
                    "main_recording_state_ready",
                    request: activeLaunchRequest
                )
            } else {
                // A stashed system PiP remains represented by an edge chevron.
                // Ending PiP with the recording removes that system-owned tab.
                pip.stop()
                showsManualReturnGuidance = false
            }
        }
        .onChange(of: recorder.audioLevel) { _, level in
            pip.setAudioLevel(level)
        }
        .onChange(of: pip.isPreparedForBackgroundTransition) { _, _ in
            if pip.isPreparedForBackgroundTransition {
                RecordingLaunchMetrics.mark(
                    "main_pip_prepared",
                    request: activeLaunchRequest
                )
            }
        }
        .onOpenURL { url in
            handleIncomingURL(url)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else {
                return
            }
            handleLatestSharedRecordingRequest()
        }
        .task {
            await observeKeyboardRecordingRequests()
        }
        .onChange(of: recordingRequestObserver.generation) { _, _ in
            handleLatestSharedRecordingRequest()
        }
        .task {
            aliyunConfigured = await Task.detached(priority: .utility) {
                AliyunCredentialStore.hasAPIKey
            }.value
        }
        .task {
            await loadDeferredHomeData()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .aliyunCredentialDidChange)
        ) { _ in
            aliyunConfigured = AliyunCredentialStore.hasAPIKey
        }
    }

    private func handleIncomingURL(_ url: URL) {
        guard url.scheme == "agenboard" else {
            return
        }

        if url.host == "phrases" {
            quickPhraseStore.refresh()
            showsQuickPhraseLibrary = true
            return
        }

        guard url.host == "record" else {
            return
        }

        let incomingRequest = recordingRequest(from: url)
        RecordingLaunchMetrics.mark(
            "main_recording_url_received",
            request: incomingRequest,
            detail: url.absoluteString
        )

        if requiresManualReturn(from: url) {
            showsManualReturnGuidance = true
        }

        if let request = incomingRequest {
            handleRecordingRequest(request)
        } else {
            if requiresManualReturn(from: url) {
                pip.prepareForAutomaticStart()
            } else {
                pip.start()
            }
            recorder.toggleRecording()
        }
    }

    private func configurePictureInPictureActions() {
        pip.onUserClosedPictureInPicture = {
            RecordingLaunchMetrics.mark(
                "main_pip_closed_by_user",
                request: activeLaunchRequest
            )
            recorder.stopRecordingAndTranscribeIfNeeded()
        }

        pip.onRestoreUserInterface = {
            RecordingLaunchMetrics.mark(
                "main_pip_restore_requested",
                request: activeLaunchRequest
            )
            showsManualReturnGuidance = false
            activeLaunchRequest = nil
            showsQuickPhraseLibrary = false
        }
    }

    private func observeKeyboardRecordingRequests() async {
        while !Task.isCancelled {
            recorder.publishCurrentSnapshot()
            handleLatestSharedRecordingRequest()

            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func handleLatestSharedRecordingRequest() {
        if let request = SharedCommandStore.latestRecordingToggleRequest() {
            handleRecordingRequest(request)
        }
    }

    private func loadDeferredHomeData() async {
        do {
            try await Task.sleep(nanoseconds: 600_000_000)
        } catch {
            return
        }

        historyStore.loadIfNeeded()
        hotwordStore.refresh()
        quickPhraseStore.refresh()
        RecordingLaunchMetrics.mark("main_deferred_home_data_loaded")
    }

    private func refreshImportedPortableData() {
        hotwordStore.refresh()
        quickPhraseStore.refresh()
        usesHotwords = RecognitionPreferences.usesHotwords
        providerRawValue = SpeechServicePreferences.provider.rawValue
        keyboardQuickPhraseModuleVisible =
            SharedCommandStore.keyboardQuickPhraseModuleVisible()
        keyboardHapticsEnabled = SharedCommandStore.keyboardHapticsEnabled()
    }

    private func recordingRequest(from url: URL) -> SharedRecordingToggleRequest? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let requestID = components.queryItems?
                .first(where: { $0.name == "requestID" })?.value else {
            return nil
        }

        let requiresForegroundRoundTrip = requiresManualReturn(from: url)

        if let sharedRequest = SharedCommandStore.latestRecordingToggleRequest(),
           sharedRequest.id == requestID {
            return SharedRecordingToggleRequest(
                id: sharedRequest.id,
                requestedAt: sharedRequest.requestedAt,
                requiresForegroundRoundTrip: requiresForegroundRoundTrip
                    || sharedRequest.requiresForegroundRoundTrip
            )
        }

        if let requestedAtValue = components.queryItems?
            .first(where: { $0.name == "requestedAt" })?.value,
           let requestedAt = TimeInterval(requestedAtValue) {
            return SharedRecordingToggleRequest(
                id: requestID,
                requestedAt: requestedAt,
                requiresForegroundRoundTrip: requiresForegroundRoundTrip
            )
        }

        return SharedRecordingToggleRequest(
            id: requestID,
            requestedAt: Date().timeIntervalSince1970,
            requiresForegroundRoundTrip: requiresForegroundRoundTrip
        )
    }

    private func handleRecordingRequest(_ request: SharedRecordingToggleRequest) {
        let age = Date().timeIntervalSince1970 - request.requestedAt
        guard age >= -2, age < recordingRequestLifetime else {
            return
        }

        guard !handledRecordingRequestIDs.contains(request.id),
              request.id != SharedCommandStore.latestHandledRecordingToggleRequestID() else {
            return
        }

        // A live App-Group request intentionally gets one background start
        // attempt so an already-established audio session can be reused without
        // switching apps. Cold/fallback requests wait until their URL launch has
        // made the scene active, avoiding a race with foreground activation.
        let requiresForeground = !recorder.isRecording
            && request.requiresForegroundRoundTrip
        guard !requiresForeground || scenePhase == .active else {
            if deferredRecordingRequestID != request.id {
                deferredRecordingRequestID = request.id
                RecordingLaunchMetrics.mark(
                    "main_recording_request_deferred_until_active",
                    request: request,
                    detail: "scene=\(String(describing: scenePhase))"
                )
            }
            return
        }

        if deferredRecordingRequestID == request.id {
            deferredRecordingRequestID = nil
            RecordingLaunchMetrics.mark(
                "main_recording_request_resumed_in_foreground",
                request: request
            )
        }

        if request.requiresForegroundRoundTrip {
            showsManualReturnGuidance = true
        }

        activeLaunchRequest = request
        RecordingLaunchMetrics.mark(
            "main_recording_request_handling",
            request: request
        )

        handledRecordingRequestIDs.insert(request.id)
        SharedCommandStore.markRecordingToggleRequestHandled(request.id)

        if request.requiresForegroundRoundTrip {
            pip.prepareForAutomaticStart()
        } else if !pip.isPictureInPictureActive {
            pip.start()
        }
        recorder.toggleRecording(request: request)
    }

    private func requiresManualReturn(from url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .contains(where: { item in
                (item.name == "manualReturn" || item.name == "returnToPrevious")
                    && item.value == "1"
            }) == true
    }
}

private final class SharedRecordingRequestObserver: ObservableObject, @unchecked Sendable {
    @Published private(set) var generation = 0

    init() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            sharedRecordingRequestNotificationCallback,
            SharedCommandStore.recordingToggleDarwinNotificationName as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(
                SharedCommandStore.recordingToggleDarwinNotificationName as CFString
            ),
            nil
        )
    }

    fileprivate func receive() {
        generation &+= 1
    }
}

private let sharedRecordingRequestNotificationCallback: CFNotificationCallback = {
    _, observer, _, _, _ in
    guard let observer else {
        return
    }

    let requestObserver = Unmanaged<SharedRecordingRequestObserver>
        .fromOpaque(observer)
        .takeUnretainedValue()
    DispatchQueue.main.async {
        requestObserver.receive()
    }
}

private struct AudioLevelMeter: View {
    let level: Double
    let isActive: Bool

    private let barCount = 24

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                let threshold = Double(index + 1) / Double(barCount)
                RoundedRectangle(cornerRadius: 2)
                    .fill(color(for: threshold))
                    .frame(height: height(for: index))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 42)
        .padding(.horizontal, 2)
        .animation(.easeOut(duration: 0.08), value: level)
    }

    private func height(for index: Int) -> CGFloat {
        guard isActive else {
            return 5
        }

        let normalizedLevel = CGFloat(max(0, min(1, level)))
        let center = CGFloat(barCount - 1) / 2
        let distanceFromCenter = abs(CGFloat(index) - center) / max(1, center)
        let envelope = 1 - distanceFromCenter * 0.48
        let texture = 0.72 + 0.28 * abs(sin(CGFloat(index) * 1.37))
        return 5 + 33 * min(1, normalizedLevel * 1.55) * envelope * texture
    }

    private func color(for threshold: Double) -> Color {
        guard isActive else {
            return .gray.opacity(0.24)
        }

        if level >= threshold {
            if threshold > 0.82 {
                return .red
            } else if threshold > 0.62 {
                return .orange
            } else {
                return .green
            }
        }

        return .gray.opacity(0.20)
    }
}

#Preview {
    ContentView()
}
