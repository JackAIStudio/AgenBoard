import SwiftUI
import UIKit

struct SpeechServiceSettingsView: View {
    private static let volcAPIKeyManagementURL = URL(
        string: "https://console.volcengine.com/speech/new/"
    )!
    private static let privacyURL = URL(
        string: "https://github.com/JackAIStudio/AgenBoard/blob/main/PRIVACY.md"
    )!

    @AppStorage(
        SpeechServicePreferences.providerKey,
        store: SpeechServicePreferences.defaults
    ) private var providerRawValue = SpeechRecognitionProvider.apple.rawValue
    @AppStorage(
        SpeechServicePreferences.volcRealtimeTranscriptionModeKey,
        store: SpeechServicePreferences.defaults
    ) private var volcRealtimeTranscriptionModeRawValue =
        VolcRealtimeTranscriptionMode.naturalDictation.rawValue
    @AppStorage(
        SpeechServicePreferences.volcResourceIDKey,
        store: SpeechServicePreferences.defaults
    ) private var resourceID = SpeechServicePreferences.defaultVolcResourceID

    @State private var apiKeyDraft = ""
    @State private var hasStoredAPIKey = VolcCredentialStore.hasAPIKey
    @State private var isAPIKeyVisible = false
    @State private var statusMessage = ""
    @State private var showsError = false
    @State private var isChecking = false

    private var provider: SpeechRecognitionProvider {
        (SpeechRecognitionProvider(rawValue: providerRawValue) ?? .apple).primaryProvider
    }

    private var volcRealtimeTranscriptionMode: VolcRealtimeTranscriptionMode {
        VolcRealtimeTranscriptionMode(
            rawValue: volcRealtimeTranscriptionModeRawValue
        ) ?? .naturalDictation
    }

    var body: some View {
        Form {
            Section {
                SpeechProviderSelectionCards(selection: $providerRawValue)
                    .padding(.vertical, 4)
            } header: {
                Text("选择识别服务")
            } footer: {
                Text("选择会立即生效。你可以随时回来切换，不会影响已经保存的识别历史。")
            }

            if provider == .volcRealtime {
                Section {
                    Picker(
                        "断句方式",
                        selection: $volcRealtimeTranscriptionModeRawValue
                    ) {
                        ForEach(VolcRealtimeTranscriptionMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(volcRealtimeTranscriptionMode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Label(
                        "停止录音后会请求非流式二遍识别结果作为最终文本",
                        systemImage: "waveform.path"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("豆包实时断句")
                } footer: {
                    Text("自然听写与 JackVoice 默认行为一致；低延迟模式会向服务端传入 1300 ms 停顿判停参数。")
                }
            }

            Section("项目的数据边界") {
                Label("项目维护者不会收到你的录音", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)

                Text("AgenBoard 不运营后端服务器、账号系统、录音中转或云存储。正常使用时，项目维护者不会收到、保存或查看你的录音、转写文本、热词或 API Key。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("每次录音及其识别历史默认保存在当前设备；在 App 中删除对应历史时，本地录音也会被删除。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Link(destination: Self.privacyURL) {
                    Label("查看完整隐私说明", systemImage: "arrow.up.right.square")
                }
            }

            if provider == .apple {
                Section("Apple 识别说明") {
                    Label(provider.detail, systemImage: "bolt.shield.fill")
                        .foregroundStyle(.blue)

                    if #available(iOS 26.0, *) {
                        Text("当前系统使用设备端 SpeechAnalyzer。首次识别可能需要下载 Apple 管理的中文语音模型，安装后由系统维护和更新。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("当前系统使用 Apple Speech 兼容路径。是否需要联网由系统、设备型号和中文语音能力决定，因此 AgenBoard 不会在这些系统上承诺完全离线。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("如果结果受方言、噪声或专业词影响，可以先完善热词词库；仍不理想时，再使用豆包实时识别重新转写同一段录音。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                    HStack {
                        Group {
                            if isAPIKeyVisible {
                                TextField("粘贴豆包语音 API Key", text: $apiKeyDraft)
                            } else {
                                SecureField("粘贴豆包语音 API Key", text: $apiKeyDraft)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                        Button {
                            isAPIKeyVisible.toggle()
                        } label: {
                            Image(systemName: isAPIKeyVisible ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isAPIKeyVisible ? "隐藏 API Key" : "显示 API Key")
                    }

                    if hasStoredAPIKey {
                        Label("API Key 已保存在本机钥匙串", systemImage: "checkmark.shield")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Label("尚未保存 API Key", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Link(destination: Self.volcAPIKeyManagementURL) {
                        Label(
                            hasStoredAPIKey ? "管理豆包语音 API Key" : "前往火山引擎开通服务",
                            systemImage: "arrow.up.right.square"
                        )
                    }

                    if hasStoredAPIKey {
                        Button {
                            UIPasteboard.general.string = apiKeyDraft
                            showsError = false
                            statusMessage = "API Key 已复制"
                        } label: {
                            Label("复制 API Key", systemImage: "doc.on.doc")
                        }
                        .disabled(apiKeyDraft.isEmpty)
                    }

                    TextField("资源 ID", text: $resourceID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Text("默认资源 ID 为 `volc.seedasr.sauc.duration`，对应豆包流式语音识别模型 2.0 小时版。除非火山控制台为你的账号给出了其他值，否则保持默认。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("保存豆包语音配置") {
                        saveConfiguration()
                    }

                    Button {
                        checkConnection()
                    } label: {
                        HStack {
                            Text("测试连接")
                            if isChecking {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isChecking || !hasStoredAPIKey)

                    if hasStoredAPIKey {
                        Button("删除本机 API Key", role: .destructive) {
                            deleteAPIKey()
                        }
                    }
            } header: {
                Text("火山引擎 · 豆包语音")
            } footer: {
                if provider == .volcRealtime {
                    Text(
                        "录音时会通过 WebSocket 将 16 kHz 单声道 PCM 直接发送到豆包双向流式优化版，实时显示一遍结果，停止后用二遍结果生成终稿。本地仍保存录音用于回放和重转写；API Key 默认只保存在本机钥匙串。"
                    )
                } else {
                    Text(
                        "Apple 仍是当前日常识别服务。保存 API Key 不会改变这个选择；它只会让你可以在识别历史中使用豆包实时接口重新转写，或以后切换日常识别服务。"
                    )
                }
            }

            Section("当前识别服务的数据去向") {
                Text(provider.privacySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if provider.usesVolc {
                    Text("实时录音、请求级热词和识别参数只会直接发送到火山引擎，并受你与火山引擎之间的服务条款约束；调用费用计入你自己的账号。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("历史重转写也使用同一条流式链路按录音时长推送，不上传临时文件。删除本机 API Key 后，历史文本和原音频仍保留，但无法继续调用豆包语音服务。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("识别服务")
        .navigationBarTitleDisplayMode(.inline)
        .alert("识别服务", isPresented: $showsError) {
            Button("好") {}
        } message: {
            Text(statusMessage)
        }
        .safeAreaInset(edge: .bottom) {
            if !statusMessage.isEmpty && !showsError {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
        .onAppear {
            loadStoredAPIKey()
        }
    }

    private func saveConfiguration() {
        do {
            let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                throw VolcSpeechServiceError.configuration(
                    "API Key 不能为空；如需移除，请使用“删除本机 API Key”。"
                )
            }
            let storedKey = try VolcCredentialStore.apiKey() ?? ""
            if key != storedKey {
                try VolcCredentialStore.saveAPIKey(key)
            }
            SpeechServicePreferences.volcResourceID = resourceID
            resourceID = SpeechServicePreferences.volcResourceID
            apiKeyDraft = key
            hasStoredAPIKey = VolcCredentialStore.hasAPIKey
            guard hasStoredAPIKey else {
                throw VolcSpeechServiceError.configuration("请填写并保存豆包语音 API Key。")
            }
            showsError = false
            statusMessage = "豆包语音配置已保存"
        } catch {
            statusMessage = error.localizedDescription
            showsError = true
        }
    }

    private func checkConnection() {
        saveConfiguration()
        guard hasStoredAPIKey, !showsError else {
            return
        }

        isChecking = true
        statusMessage = "正在验证豆包实时连接…"
        Task { @MainActor in
            defer { isChecking = false }
            do {
                try await VolcRealtimeSpeechTranscriber.validateConfiguration()
                showsError = false
                statusMessage = "连接成功，实时识别与历史重转写可用"
            } catch {
                statusMessage = error.localizedDescription
                showsError = true
            }
        }
    }

    private func deleteAPIKey() {
        do {
            try VolcCredentialStore.deleteAPIKey()
            apiKeyDraft = ""
            hasStoredAPIKey = false
            isAPIKeyVisible = false
            showsError = false
            statusMessage = "本机 API Key 已删除"
        } catch {
            statusMessage = error.localizedDescription
            showsError = true
        }
    }

    private func loadStoredAPIKey() {
        do {
            apiKeyDraft = try VolcCredentialStore.apiKey() ?? ""
            hasStoredAPIKey = !apiKeyDraft.isEmpty
            resourceID = SpeechServicePreferences.volcResourceID
        } catch {
            apiKeyDraft = ""
            hasStoredAPIKey = false
            statusMessage = error.localizedDescription
            showsError = true
        }
    }
}

#Preview {
    NavigationStack {
        SpeechServiceSettingsView()
    }
}
