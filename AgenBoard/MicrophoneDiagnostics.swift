@preconcurrency import AVFoundation
import SwiftUI

struct MicrophoneInputOption: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let type: String

    var detail: String {
        switch type {
        case AVAudioSession.Port.builtInMic.rawValue:
            return "设备内置麦克风"
        case AVAudioSession.Port.headsetMic.rawValue:
            return "有线耳机麦克风"
        case AVAudioSession.Port.bluetoothHFP.rawValue:
            return "蓝牙通话麦克风"
        case AVAudioSession.Port.usbAudio.rawValue:
            return "USB 音频输入"
        default:
            return type
        }
    }
}

@MainActor
enum AudioSessionRouting {
    static func configureForRecording(
        _ session: AVAudioSession = .sharedInstance()
    ) throws {
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.defaultToSpeaker, .mixWithOthers, .allowBluetoothHFP]
        )
    }

    @discardableResult
    static func applyStoredPreferredInput(
        to session: AVAudioSession = .sharedInstance()
    ) throws -> AVAudioSessionPortDescription? {
        guard let preferredUID = SpeechServicePreferences.preferredMicrophoneUID else {
            try session.setPreferredInput(nil)
            return nil
        }
        guard let input = session.availableInputs?.first(where: {
            $0.uid == preferredUID
        }) else {
            // 设备暂时不可用时保留偏好，方便耳机重新连接后继续使用；
            // 当前录音则明确回退到系统选择的输入。
            try session.setPreferredInput(nil)
            return nil
        }
        try session.setPreferredInput(input)
        return input
    }

    static func availableInputOptions(
        in session: AVAudioSession = .sharedInstance()
    ) -> [MicrophoneInputOption] {
        (session.availableInputs ?? []).map {
            MicrophoneInputOption(
                id: $0.uid,
                name: $0.portName,
                type: $0.portType.rawValue
            )
        }
    }

    static func currentInputDescription(
        in session: AVAudioSession = .sharedInstance()
    ) -> String {
        let inputs = session.currentRoute.inputs
        guard !inputs.isEmpty else {
            return "当前没有活动输入"
        }
        return inputs.map(\.portName).joined(separator: "、")
    }
}

@MainActor
final class MicrophoneDiagnosticsModel: ObservableObject {
    @Published private(set) var inputs: [MicrophoneInputOption] = []
    @Published var selectedInputUID: String
    @Published private(set) var currentInputDescription = "正在读取…"
    @Published private(set) var isTesting = false
    @Published private(set) var isStartingTest = false
    @Published private(set) var audioLevel = 0.0
    @Published private(set) var peakAudioLevel = 0.0
    @Published private(set) var decibels = -80.0
    @Published private(set) var status = "选择麦克风后可进行本地音量测试"
    @Published var alertMessage = ""
    @Published var showsAlert = false

    private var engine: AVAudioEngine?
    private var routeObserver: NSObjectProtocol?
    private var smoothedLevel = 0.0

    init() {
        selectedInputUID = SpeechServicePreferences.preferredMicrophoneUID ?? ""
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        refresh()
    }

    deinit {
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
        }
    }

    func refresh() {
        let session = AVAudioSession.sharedInstance()
        if !isTesting {
            try? AudioSessionRouting.configureForRecording(session)
        }
        inputs = AudioSessionRouting.availableInputOptions(in: session)
        currentInputDescription = AudioSessionRouting.currentInputDescription(
            in: session
        )

        if selectedInputUID.isEmpty,
           let preferredUID = SpeechServicePreferences.preferredMicrophoneUID {
            selectedInputUID = preferredUID
        }
        if !selectedInputUID.isEmpty,
           !inputs.contains(where: { $0.id == selectedInputUID }) {
            status = "首选麦克风当前未连接，录音时会回退到系统输入"
        }
    }

    func selectInput(uid: String) {
        selectedInputUID = uid
        SpeechServicePreferences.preferredMicrophoneUID = uid.isEmpty ? nil : uid
        guard isTesting else {
            status = uid.isEmpty
                ? "已改为每次由系统自动选择麦克风"
                : "首选麦克风已保存，下次录音会优先使用"
            return
        }

        do {
            try AudioSessionRouting.applyStoredPreferredInput()
            refresh()
            status = "已切换输入，可继续说话测试"
        } catch {
            present(error: error, prefix: "无法切换麦克风")
        }
    }

    func toggleTest() {
        guard !isStartingTest else {
            return
        }
        if isTesting {
            stopTest()
        } else {
            Task { @MainActor [weak self] in
                await self?.startTest()
            }
        }
    }

    func stopTest() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        self.engine = nil
        isTesting = false
        isStartingTest = false
        audioLevel = 0
        smoothedLevel = 0
        status = "测试已停止；选择会保留给下次正式录音"
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        refresh()
    }

    private func startTest() async {
        isStartingTest = true
        defer {
            if !isTesting {
                isStartingTest = false
            }
        }
        guard await SpeechPermissionRequester.requestMicrophone() else {
            alertMessage = "请在系统设置中允许 AgenBoard 使用麦克风。"
            showsAlert = true
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try AudioSessionRouting.configureForRecording(session)
            try session.setActive(true)
            try AudioSessionRouting.applyStoredPreferredInput(to: session)

            let engine = AVAudioEngine()
            self.engine = engine
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw VolcSpeechServiceError.configuration(
                    "当前麦克风没有提供有效音频格式。"
                )
            }
            input.installTap(
                onBus: 0,
                bufferSize: 1_024,
                format: format
            ) { [weak self] buffer, _ in
                let level = Self.meterValue(from: buffer)
                Task { @MainActor [weak self] in
                    self?.receiveMeter(decibels: level)
                }
            }
            engine.prepare()
            try engine.start()
            isTesting = true
            isStartingTest = false
            peakAudioLevel = 0
            status = "正在本地测试；请对着麦克风说话"
            refresh()
        } catch {
            stopTest()
            present(error: error, prefix: "无法开始麦克风测试")
        }
    }

    nonisolated private static func meterValue(
        from buffer: AVAudioPCMBuffer
    ) -> Double {
        guard let channels = buffer.floatChannelData,
              buffer.frameLength > 0 else {
            return -80
        }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var squareSum = 0.0
        for channel in 0..<channelCount {
            for frame in 0..<frameCount {
                let sample = Double(channels[channel][frame])
                squareSum += sample * sample
            }
        }
        let rms = sqrt(
            squareSum / Double(max(1, frameCount * channelCount))
        )
        return max(-80, 20 * log10(max(rms, 0.000_1)))
    }

    private func receiveMeter(decibels: Double) {
        guard isTesting else {
            return
        }
        self.decibels = decibels
        let linear = max(0, min(1, (decibels + 55) / 45))
        let perceptual = pow(linear, 0.68)
        smoothedLevel = smoothedLevel * 0.32 + perceptual * 0.68
        audioLevel = smoothedLevel
        peakAudioLevel = max(peakAudioLevel, smoothedLevel)
    }

    private func present(error: Error, prefix: String) {
        alertMessage = "\(prefix)：\(error.localizedDescription)"
        showsAlert = true
    }
}

struct MicrophoneDiagnosticsView: View {
    @StateObject private var model = MicrophoneDiagnosticsModel()

    var body: some View {
        Form {
            Section("当前音频路由") {
                Label(
                    model.currentInputDescription,
                    systemImage: "mic.and.signal.meter"
                )

                Button("刷新设备列表") {
                    model.refresh()
                }
            }

            Section {
                Picker(
                    "首选麦克风",
                    selection: Binding(
                        get: { model.selectedInputUID },
                        set: { model.selectInput(uid: $0) }
                    )
                ) {
                    Text("跟随系统").tag("")
                    ForEach(model.inputs) { input in
                        VStack(alignment: .leading) {
                            Text(input.name)
                            Text(input.detail)
                        }
                        .tag(input.id)
                    }
                }

                Text("iOS 只会列出当前可用于录音的输入。蓝牙耳机需要支持通话麦克风，并可能使用通话音质。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("切换麦克风")
            }

            Section {
                HStack {
                    Text("实时音量")
                    Spacer()
                    Text("\(Int(model.decibels.rounded())) dB")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                AudioLevelMeter(
                    level: model.audioLevel,
                    isActive: model.isTesting
                )

                Button {
                    model.toggleTest()
                } label: {
                    Label(
                        model.isTesting ? "停止测试" : "开始麦克风测试",
                        systemImage: model.isTesting ? "stop.fill" : "mic.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isStartingTest)

                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("本地测试")
            } footer: {
                Text("测试音频只用于本页音量计，不会保存、转写或发送到云端。AgenBoard 暂不做数字增益，避免在不了解噪声底的情况下同时放大底噪和削波。")
            }
        }
        .navigationTitle("麦克风")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            model.stopTest()
        }
        .alert("麦克风", isPresented: $model.showsAlert) {
            Button("好") {}
        } message: {
            Text(model.alertMessage)
        }
    }
}
