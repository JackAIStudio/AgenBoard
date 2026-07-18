import SwiftUI
import UIKit

struct SpeechServiceSettingsView: View {
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
            Section("识别服务") {
                Picker("当前服务", selection: $providerRawValue) {
                    ForEach(SpeechRecognitionProvider.allCases) { provider in
                        Label(provider.title, systemImage: provider.systemImage)
                            .tag(provider.rawValue)
                    }
                }
                .pickerStyle(.inline)

                Text(provider.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Group {
                        if isAPIKeyVisible {
                            TextField("API Key（sk-…）", text: $apiKeyDraft)
                        } else {
                            SecureField("API Key（sk-…）", text: $apiKeyDraft)
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

                Text("当前个人版固定使用北京 DashScope 接入点，无需填写 Workspace ID。请使用在华北 2（北京）创建的百炼 API Key。")
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
                    "阿里云模式会把录音上传到百炼临时存储，再调用 fun-asr 整段识别；启用热词时同步当前最多 100 个激活词，权重固定为 5。API Key 默认隐藏，可按需显示或复制，并且不会写入项目文件或 UserDefaults。"
                )
            }

            Section("安全说明") {
                Text(
                    "当前方式适合你个人设备上的 MVP。若以后对外分发 App，应改为由自己的服务端保管 API Key，并给客户端签发短期凭证。"
                )
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
                statusMessage = error.localizedDescription
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
