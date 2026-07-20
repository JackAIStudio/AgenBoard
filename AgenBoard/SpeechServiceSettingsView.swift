import SwiftUI
import UIKit

struct SpeechServiceSettingsView: View {
    private static let aliyunAPIKeyManagementURL = URL(
        string: "https://bailian.console.aliyun.com/cn-beijing?tab=model#/api-key"
    )!
    private static let privacyURL = URL(
        string: "https://github.com/JackAIStudio/AgenBoard/blob/main/PRIVACY.md"
    )!

    @AppStorage(
        SpeechServicePreferences.providerKey,
        store: SpeechServicePreferences.defaults
    ) private var providerRawValue = SpeechRecognitionProvider.apple.rawValue

    @State private var apiKeyDraft = ""
    @State private var hasStoredAPIKey = AliyunCredentialStore.hasAPIKey
    @State private var isAPIKeyVisible = false
    @State private var statusMessage = ""
    @State private var showsError = false
    @State private var isChecking = false

    private var provider: SpeechRecognitionProvider {
        SpeechRecognitionProvider(rawValue: providerRawValue) ?? .apple
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

                    Text("如果结果受方言、噪声或专业词影响，可以先完善热词词库；仍不理想时，再切换到阿里云进行同一段录音的识别。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if provider == .aliyun {
                Section {
                    HStack {
                        Group {
                            if isAPIKeyVisible {
                                TextField("粘贴百炼 API Key", text: $apiKeyDraft)
                            } else {
                                SecureField("粘贴百炼 API Key", text: $apiKeyDraft)
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

                    Link(destination: Self.aliyunAPIKeyManagementURL) {
                        Label(
                            hasStoredAPIKey ? "管理百炼 API Key" : "前往百炼创建 API Key",
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

                    Label("服务地域：华北 2（北京）", systemImage: "mappin.and.ellipse")
                        .font(.callout)

                    Text("当前版本固定使用华北 2（北京）的 DashScope 接入点，无需填写 Workspace ID。其他地域创建的 API Key 无法在当前版本中使用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("新创建的 API Key 明文只在阿里云控制台显示一次，请创建后立即复制并妥善保存。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("保存阿里云配置") {
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
                    Text("阿里云百炼")
                } footer: {
                    Text(
                        "阿里云模式会把录音直传百炼托管的私有临时存储，再调用 fun-asr 整段识别；临时录音在 48 小时后由阿里云自动清理，无需另行开通 OSS。启用热词时会同步当前最多 100 个激活词。API Key 默认只保存在本机钥匙串，仅在你主动选择导出时才会进入数据包。"
                    )
                }
            }

            Section("当前识别服务的数据去向") {
                Text(provider.privacySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if provider == .aliyun {
                    Text("录音、已启用热词和识别请求只会直接发送到阿里云，并受你与阿里云之间的服务条款约束；产生的调用费用计入你自己的百炼账号。删除本机 API Key 后，AgenBoard 将无法继续调用该服务。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                throw AliyunSpeechServiceError.configuration(
                    "API Key 不能为空；如需移除，请使用“删除本机 API Key”。"
                )
            }
            let storedKey = try AliyunCredentialStore.apiKey() ?? ""
            if key != storedKey {
                try AliyunCredentialStore.saveAPIKey(key)
            }
            apiKeyDraft = key
            hasStoredAPIKey = AliyunCredentialStore.hasAPIKey
            guard hasStoredAPIKey else {
                throw AliyunSpeechServiceError.configuration("请填写并保存阿里云百炼 API Key。")
            }
            showsError = false
            statusMessage = "阿里云配置已保存"
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
        statusMessage = "正在验证阿里云连接…"
        Task { @MainActor in
            defer { isChecking = false }
            do {
                try await AliyunSpeechTranscriber.validateConfiguration()
                showsError = false
                statusMessage = "连接成功，fun-asr 与热词服务可用"
            } catch {
                statusMessage = """
                \(error.localizedDescription)
                如果凭证无效，请确认 API Key 创建于华北 2（北京）地域。
                """
                showsError = true
            }
        }
    }

    private func deleteAPIKey() {
        do {
            try AliyunCredentialStore.deleteAPIKey()
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
            apiKeyDraft = try AliyunCredentialStore.apiKey() ?? ""
            hasStoredAPIKey = !apiKeyDraft.isEmpty
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
