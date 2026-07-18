import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import SwiftUI
import UIKit

private final class PictureInPictureRestoreCompletion: @unchecked Sendable {
    private let completionHandler: (Bool) -> Void

    init(_ completionHandler: @escaping (Bool) -> Void) {
        self.completionHandler = completionHandler
    }

    func finish(restored: Bool) {
        completionHandler(restored)
    }
}

@MainActor
private final class PictureInPictureFrameRenderer {
    private static let frameSize = CGSize(width: 640, height: 360)
    private static let frameDuration = CMTime(value: 1, timescale: 30)

    private weak var displayLayer: AVSampleBufferDisplayLayer?
    private let hostClock = CMClockGetHostTimeClock()
    private var pixelBufferPool: CVPixelBufferPool?
    private var formatDescription: CMVideoFormatDescription?
    private var controlTimebase: CMTimebase?
    private var waveformPhase: CGFloat = 0

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: Int(Self.frameSize.width),
            kCVPixelBufferHeightKey: Int(Self.frameSize.height),
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            nil,
            attributes as CFDictionary,
            &pool
        )
        pixelBufferPool = pool

        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: hostClock,
            timebaseOut: &timebase
        )
        controlTimebase = timebase
        if let timebase {
            CMTimebaseSetTime(timebase, time: CMClockGetTime(hostClock))
            CMTimebaseSetRate(timebase, rate: 1)
            displayLayer.controlTimebase = timebase
        }

        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.backgroundColor = UIColor.systemGray5.cgColor
    }

    func render(isRecording: Bool, audioLevel: Double) {
        guard let displayLayer,
              let pixelBufferPool,
              displayLayer.isReadyForMoreMediaData else {
            return
        }

        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pixelBufferPool,
            &pixelBuffer
        ) == kCVReturnSuccess,
              let pixelBuffer,
              let image = makeFrameImage(
                isRecording: isRecording,
                audioLevel: audioLevel
              ).cgImage,
              draw(image: image, into: pixelBuffer) else {
            return
        }

        if formatDescription == nil {
            var description: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &description
            ) == noErr else {
                return
            }
            formatDescription = description
        }

        guard let formatDescription else {
            return
        }

        var timing = CMSampleTimingInfo(
            duration: Self.frameDuration,
            presentationTimeStamp: CMClockGetTime(hostClock),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr,
              let sampleBuffer else {
            return
        }

        CMSetAttachment(
            sampleBuffer,
            key: kCMSampleAttachmentKey_DisplayImmediately,
            value: kCFBooleanTrue,
            attachmentMode: kCMAttachmentMode_ShouldNotPropagate
        )

        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
    }

    private func makeFrameImage(
        isRecording: Bool,
        audioLevel: Double
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(
            size: Self.frameSize,
            format: format
        ).image { context in
            let bounds = CGRect(origin: .zero, size: Self.frameSize)
            UIColor.systemGray5.setFill()
            context.fill(bounds)

            let circle = CGRect(x: 224, y: 24, width: 192, height: 192)
            UIColor.black.setFill()
            context.cgContext.fillEllipse(in: circle)

            if isRecording {
                drawWaveform(
                    in: context.cgContext,
                    circle: circle,
                    level: audioLevel
                )
            } else if let icon = UIImage(
                systemName: "mic.fill",
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: 96,
                    weight: .medium
                )
            )?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                icon.draw(in: CGRect(x: 272, y: 72, width: 96, height: 96))
            }

            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            let title = isRecording ? "Recording" : "AgenBoard"
            (title as NSString).draw(
                in: CGRect(x: 32, y: 230, width: 576, height: 50),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 38, weight: .semibold),
                    .foregroundColor: UIColor.label,
                    .paragraphStyle: paragraphStyle
                ]
            )

            let subtitle = isRecording ? "正在听写" : "语音输入待命"
            (subtitle as NSString).draw(
                in: CGRect(x: 32, y: 292, width: 576, height: 40),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 28, weight: .regular),
                    .foregroundColor: UIColor.secondaryLabel,
                    .paragraphStyle: paragraphStyle
                ]
            )
        }
    }

    private func drawWaveform(
        in context: CGContext,
        circle: CGRect,
        level: Double
    ) {
        let weights: [CGFloat] = [0.5, 0.72, 0.9, 1, 0.9, 0.72, 0.5]
        let barWidth: CGFloat = 12
        let spacing: CGFloat = 10
        let totalWidth = CGFloat(weights.count) * barWidth
            + CGFloat(weights.count - 1) * spacing
        let startX = circle.midX - totalWidth / 2
        let energy = min(1, max(0.08, CGFloat(level) * 1.65))
        waveformPhase += 0.72

        UIColor.white.setFill()
        for (index, weight) in weights.enumerated() {
            let oscillation = 0.62
                + 0.38 * abs(sin(waveformPhase + CGFloat(index) * 0.83))
            let height = 14 + 82 * energy * weight * oscillation
            let rect = CGRect(
                x: startX + CGFloat(index) * (barWidth + spacing),
                y: circle.midY - height / 2,
                width: barWidth,
                height: height
            )
            UIBezierPath(roundedRect: rect, cornerRadius: barWidth / 2).fill()
        }
    }

    private func draw(
        image: CGImage,
        into pixelBuffer: CVPixelBuffer
    ) -> Bool {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return false
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            return false
        }

        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        return true
    }
}

@MainActor
final class PictureInPictureCoordinator: NSObject, ObservableObject {
    @Published var status = "画中画未启动"
    @Published var isPictureInPictureActive = false
    @Published private(set) var isPreparedForBackgroundTransition = false

    private enum PendingAction {
        case startImmediately
        case prepareAutomaticStart
    }

    private enum StopIntent {
        case programmatic
        case restoreUserInterface
    }

    private weak var sourceView: UIView?
    private var controller: AVPictureInPictureController?
    private var contentViewController: AgenBoardPiPContentViewController?
    private var frameRenderer: PictureInPictureFrameRenderer?
    private var pendingAction: PendingAction?
    private var startRetryTask: Task<Void, Never>?
    private var stopIntent: StopIntent?
    private var isRecording = false
    private var audioLevel = 0.0
    private var lastFrameRenderTime = 0.0

    var onUserClosedPictureInPicture: (() -> Void)?
    var onRestoreUserInterface: (() -> Void)?

    var buttonTitle: String {
        isPictureInPictureActive ? "停止画中画" : "启动画中画"
    }

    var buttonIcon: String {
        isPictureInPictureActive ? "pip.exit" : "pip.enter"
    }

    func attachSourceView(_ view: UIView) {
        guard sourceView !== view else {
            return
        }

        sourceView = view

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            self.configureIfPossible()
            self.attemptPendingAction()
        }
    }

    func toggle() {
        if isPictureInPictureActive {
            stopPictureInPicture(intent: .programmatic)
        } else {
            start()
        }
    }

    func start() {
        pendingAction = .startImmediately
        attemptPendingAction()
    }

    func stop() {
        pendingAction = nil
        startRetryTask?.cancel()
        startRetryTask = nil

        if controller?.isPictureInPictureActive == true {
            stopPictureInPicture(intent: .programmatic)
        } else {
            isPreparedForBackgroundTransition = false
        }
    }

    func prepareForAutomaticStart() {
        if isPictureInPictureActive {
            isPreparedForBackgroundTransition = true
            return
        }

        pendingAction = .prepareAutomaticStart
        attemptPendingAction()
    }

    private func attemptPendingAction() {
        guard let pendingAction else {
            return
        }

        configureIfPossible()

        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            self.pendingAction = nil
            isPreparedForBackgroundTransition = false
            status = "当前设备不支持画中画"
            return
        }

        guard let controller else {
            status = "正在准备画中画"
            scheduleStartRetry()
            return
        }

        guard !controller.isPictureInPictureActive else {
            self.pendingAction = nil
            startRetryTask?.cancel()
            startRetryTask = nil
            isPreparedForBackgroundTransition = true
            return
        }

        guard controller.isPictureInPicturePossible else {
            status = "正在等待画中画可用"
            scheduleStartRetry()
            return
        }

        // Automatic recording startup owns the audio session activation. Avoid
        // activating it twice on the critical path; manual PiP still prepares it.
        if case .startImmediately = pendingAction {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .mixWithOthers])
                try session.setActive(true)
            } catch {
                status = "音频会话配置失败"
            }
        }

        self.pendingAction = nil
        startRetryTask?.cancel()
        startRetryTask = nil
        isPreparedForBackgroundTransition = true

        switch pendingAction {
        case .startImmediately:
            controller.startPictureInPicture()
        case .prepareAutomaticStart:
            // The video-call PiP route starts automatically when the app moves
            // to the background. Mark it ready first so ContentView can return
            // to the keyboard host; explicitly starting here can stall a cold
            // launch because the source transition has not begun yet.
            status = "画中画已准备，正在返回原 App"
        }
    }

    private func scheduleStartRetry() {
        guard startRetryTask == nil else {
            return
        }

        startRetryTask = Task { @MainActor [weak self] in
            for _ in 0..<30 {
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    return
                }

                guard let self, self.pendingAction != nil else {
                    return
                }

                self.configureIfPossible()

                if self.controller?.isPictureInPicturePossible == true {
                    self.startRetryTask = nil
                    self.attemptPendingAction()
                    return
                }
            }

            guard let self else {
                return
            }

            self.pendingAction = nil
            self.startRetryTask = nil
            self.isPreparedForBackgroundTransition = false
            self.status = "画中画暂时不可用，请在真机上测试"
        }
    }

    func setRecordingState(_ isRecording: Bool) {
        self.isRecording = isRecording
        renderFrame(force: true)
    }

    func setAudioLevel(_ level: Double) {
        audioLevel = max(0, min(1, level))
        renderFrame()
    }

    private func renderFrame(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastFrameRenderTime >= 1.0 / 12.0 else {
            return
        }

        lastFrameRenderTime = now
        frameRenderer?.render(
            isRecording: isRecording,
            audioLevel: audioLevel
        )
    }

    private func stopPictureInPicture(intent: StopIntent) {
        guard controller?.isPictureInPictureActive == true else {
            return
        }

        stopIntent = intent
        controller?.stopPictureInPicture()
    }

    private func configureIfPossible() {
        guard controller == nil, let sourceView else {
            return
        }

        guard #available(iOS 15.0, *) else {
            status = "需要 iOS 15 或更高版本"
            return
        }

        let contentViewController = AgenBoardPiPContentViewController()
        contentViewController.preferredContentSize = CGSize(width: 320, height: 180)
        contentViewController.loadViewIfNeeded()

        let frameRenderer = PictureInPictureFrameRenderer(
            displayLayer: contentViewController.sampleBufferDisplayLayer
        )
        self.frameRenderer = frameRenderer
        renderFrame(force: true)

        let contentSource = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: sourceView,
            contentViewController: contentViewController
        )

        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true

        // AVKit has no public switch for the compact video-call chrome. This
        // guarded KVC is the same compatibility path used by LiveKit's minimal
        // PiP example: style 1 keeps Close and Restore visible while removing
        // playback, skip and timeline controls. Style 2 would hide everything.
        let controlsStyleSelector = NSSelectorFromString("setControlsStyle:")
        if controller.responds(to: controlsStyleSelector) {
            controller.setValue(1, forKey: "controlsStyle")
        }

        self.contentViewController = contentViewController
        self.controller = controller
        status = controller.isPictureInPicturePossible ? "画中画已准备" : "画中画等待系统允许"
    }
}

extension PictureInPictureCoordinator: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.status = "正在启动画中画"
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.pendingAction = nil
            self.startRetryTask?.cancel()
            self.startRetryTask = nil
            self.isPictureInPictureActive = true
            self.isPreparedForBackgroundTransition = true
            self.status = "画中画运行中"
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            let shouldFinishRecording = self.stopIntent == nil
            self.stopIntent = nil
            self.isPictureInPictureActive = false
            self.isPreparedForBackgroundTransition = false
            self.status = "画中画已停止"

            if shouldFinishRecording {
                self.onUserClosedPictureInPicture?()
            }
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        let restoreCompletion = PictureInPictureRestoreCompletion(completionHandler)
        Task { @MainActor in
            self.stopIntent = .restoreUserInterface
            self.status = "正在返回 AgenBoard"
            self.onRestoreUserInterface?()
            restoreCompletion.finish(restored: true)
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor in
            self.pendingAction = nil
            self.startRetryTask?.cancel()
            self.startRetryTask = nil
            self.isPictureInPictureActive = false
            self.isPreparedForBackgroundTransition = false
            self.status = "画中画启动失败：\(error.localizedDescription)"
        }
    }
}

struct PictureInPictureSourceView: UIViewRepresentable {
    @ObservedObject var coordinator: PictureInPictureCoordinator

    func makeUIView(context: Context) -> UIView {
        let view = PiPSourceUIView()
        view.backgroundColor = .black
        coordinator.attachSourceView(view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        coordinator.attachSourceView(uiView)
    }
}

private final class PiPSourceUIView: UIView {
    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }
}

final class AgenBoardPiPContentViewController: AVPictureInPictureVideoCallViewController {
    var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer {
        guard let displayLayer = view.layer as? AVSampleBufferDisplayLayer else {
            preconditionFailure("AgenBoard PiP view must use AVSampleBufferDisplayLayer")
        }
        return displayLayer
    }

    override func loadView() {
        let renderingView = PiPSourceUIView()
        renderingView.backgroundColor = .systemGray5
        view = renderingView
    }
}
