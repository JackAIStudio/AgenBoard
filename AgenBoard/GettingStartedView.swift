import SwiftUI
import UIKit

enum GettingStartedPreferences {
    static let hasSeenGuideKey = "hasSeenGettingStartedGuideV1"
}

extension Notification.Name {
    static let keyboardAccessVerificationDidChange = Notification.Name(
        "dev.local.agenboard.keyboard-access-verification-did-change"
    )
}

struct GettingStartedView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(GettingStartedPreferences.hasSeenGuideKey)
    private var hasSeenGuide = false
    @AppStorage(
        SpeechServicePreferences.providerKey,
        store: SpeechServicePreferences.defaults
    ) private var providerRawValue = SpeechRecognitionProvider.apple.rawValue

    @State private var keyboardVerification =
        SharedCommandStore.latestKeyboardAccessVerification()
    @State private var verificationText = ""
    @FocusState private var verificationFieldIsFocused: Bool

    let showsCompletionAction: Bool

    init(showsCompletionAction: Bool = false) {
        self.showsCompletionAction = showsCompletionAction
    }

    private var provider: SpeechRecognitionProvider {
        SpeechRecognitionProvider(rawValue: providerRawValue) ?? .apple
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                guideHero

                GuideStepCard(
                    number: 1,
                    title: "启用 AgenBoard 键盘",
                    subtitle: "系统只允许你本人添加第三方键盘并开启完全访问。"
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        GuideInstructionRow(number: 1, text: "打开 iPhone“设置”")
                        GuideInstructionRow(number: 2, text: "进入“通用 → 键盘 → 键盘”")
                        GuideInstructionRow(number: 3, text: "添加“AgenBoard”，再打开“允许完全访问”")

                        Button {
                            openSystemSettings()
                        } label: {
                            Label("打开系统设置", systemImage: "gear")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                fullAccessExplanation

                GuideStepCard(
                    number: 2,
                    title: "验证键盘状态",
                    subtitle: "由键盘扩展亲自检查，而不是根据历史数据猜测。"
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        keyboardVerificationStatus

                        TextField("点这里，然后切换到 AgenBoard 键盘", text: $verificationText)
                            .focused($verificationFieldIsFocused)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.done)

                        Button {
                            beginKeyboardVerification()
                        } label: {
                            Label(
                                keyboardVerification?.isVerified == true
                                    ? "重新验证"
                                    : "开始验证",
                                systemImage: "keyboard"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Text("点击验证后，在输入框中通过地球键切换到 AgenBoard。若完全访问已开启，状态会自动变绿。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                GuideStepCard(
                    number: 3,
                    title: "选择识别服务",
                    subtitle: "两种服务没有绝对的好坏，按速度、隐私和准确度需求选择。"
                ) {
                    SpeechProviderSelectionCards(selection: $providerRawValue)
                }

                if provider == .aliyun {
                    aliyunConfigurationPrompt
                }

                openSourcePromise

                if showsCompletionAction {
                    Button {
                        completeGuide()
                    } label: {
                        Label("完成设置，开始使用", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(showsCompletionAction ? "首次使用" : "使用指南")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCompletionAction {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("稍后") {
                        completeGuide()
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                keyboardVerification =
                    SharedCommandStore.latestKeyboardAccessVerification()
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        .onDisappear {
            NotificationCenter.default.post(
                name: .keyboardAccessVerificationDidChange,
                object: nil
            )
        }
    }

    private var guideHero: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 72, height: 72)

                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 31, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Text("欢迎使用 AgenBoard")
                .font(.largeTitle.bold())

            Text("一个开源的 AI 语音输入键盘。用几分钟完成键盘授权并选择适合你的识别服务，之后就可以在其他 App 中直接说话输入。")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private var fullAccessExplanation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("为什么需要“允许完全访问”？", systemImage: "hand.raised.fill")
                .font(.headline)
                .foregroundStyle(.blue)

            Text("AgenBoard 需要通过 App Group 在键盘与主 App 之间同步录音指令、识别结果、设置、热词和快捷短语。不开启时，普通键盘仍可输入，但语音回填和同步功能无法正常工作。")

            Divider()

            Label("键盘扩展本身不发起网络请求", systemImage: "checkmark.shield.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)

            Text("iOS 会对所有申请完全访问的第三方键盘显示统一的风险提示。AgenBoard 不包含广告、用户画像或第三方分析 SDK；阿里云模式的联网发生在主 App，并且只在你主动录音识别时发生。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color.blue.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var keyboardVerificationStatus: some View {
        if let keyboardVerification, let verifiedAt = keyboardVerification.verifiedAt {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("允许完全访问 · 已验证")
                        .font(.subheadline.weight(.semibold))
                    Text(Date(timeIntervalSince1970: verifiedAt).formatted(
                        date: .abbreviated,
                        time: .shortened
                    ))
                    .font(.caption)
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .foregroundStyle(.green)
        } else if keyboardVerification != nil {
            Label("等待 AgenBoard 键盘响应", systemImage: "clock.badge.questionmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
        } else {
            Label("尚未验证", systemImage: "exclamationmark.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
        }
    }

    private var aliyunConfigurationPrompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("还需配置你的百炼 API Key", systemImage: "key.fill")
                .font(.headline)

            Text("API Key 来自你自己的阿里云百炼账号，调用费用也由该账号承担。AgenBoard 只把 Key 保存在本机钥匙串，不会写入源代码、项目配置或 UserDefaults。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            NavigationLink {
                SpeechServiceSettingsView()
            } label: {
                Label("配置阿里云识别", systemImage: "arrow.right.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var openSourcePromise: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("开源，也要把数据流向讲清楚", systemImage: "curlybraces.square")
                .font(.headline)

            Text("Apple 模式由系统语音能力处理；阿里云模式由主 App 使用你的 API Key 直连百炼。识别历史、热词、快捷短语和设置默认保存在本机或 App Group 中。所有实现都可以在项目源代码中审查。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        UIApplication.shared.open(url)
    }

    private func beginKeyboardVerification() {
        keyboardVerification = SharedCommandStore.requestKeyboardAccessVerification()
        verificationFieldIsFocused = true
    }

    private func completeGuide() {
        hasSeenGuide = true
        dismiss()
    }
}

struct SpeechProviderSelectionCards: View {
    @Binding var selection: String

    var body: some View {
        VStack(spacing: 12) {
            ForEach(SpeechRecognitionProvider.allCases) { provider in
                SpeechProviderChoiceCard(
                    provider: provider,
                    isSelected: selection == provider.rawValue
                ) {
                    selection = provider.rawValue
                }
            }
        }
    }
}

private struct SpeechProviderChoiceCard: View {
    let provider: SpeechRecognitionProvider
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: provider.systemImage)
                        .font(.title2)
                        .foregroundStyle(isSelected ? .white : .blue)
                        .frame(width: 42, height: 42)
                        .background(isSelected ? Color.blue : Color.blue.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 11))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(provider.guidanceTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isSelected ? Color.blue : Color.secondary)
                    }

                    Spacer()

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.blue : Color.secondary)
                }

                Text(provider.guidanceSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 7) {
                    ForEach(provider.guidanceStrengths, id: \.self) { item in
                        GuideBulletRow(
                            text: item,
                            systemImage: "checkmark",
                            color: .green
                        )
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 7) {
                    ForEach(provider.guidanceConsiderations, id: \.self) { item in
                        GuideBulletRow(
                            text: item,
                            systemImage: "info",
                            color: .orange
                        )
                    }
                }

                Text(provider.privacySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .padding(14)
            .background(isSelected ? Color.blue.opacity(0.08) : Color(uiColor: .secondarySystemGroupedBackground))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color.blue : Color.secondary.opacity(0.18), lineWidth: isSelected ? 2 : 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct GuideStepCard<Content: View>: View {
    let number: Int
    let title: String
    let subtitle: String
    let content: Content

    init(
        number: Int,
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) {
        self.number = number
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Text("\(number)")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.blue)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.title3.bold())
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            content
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

private struct GuideInstructionRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.blue)
                .frame(width: 20, height: 20)
                .background(Color.blue.opacity(0.1))
                .clipShape(Circle())
            Text(text)
                .font(.subheadline)
        }
    }
}

private struct GuideBulletRow: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption.bold())
                .foregroundStyle(color)
                .frame(width: 14)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack {
        GettingStartedView(showsCompletionAction: true)
    }
}
