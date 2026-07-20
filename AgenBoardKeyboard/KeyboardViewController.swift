import UIKit

final class KeyboardViewController: UIInputViewController,
    UICollectionViewDataSource,
    UICollectionViewDelegateFlowLayout {
    private static let pinyinCandidatePageSize = 48
    private static let pinyinCandidateCellIdentifier = "PinyinCandidateCell"
    private enum ContentModule: Int {
        case voice = 0
        case phrases = 1
        case keyboard = 2
    }

    private enum KeyboardPage {
        case letters
        case numbers
        case symbols
    }

    private enum KeyboardLanguage {
        case pinyin
        case english

        var switchTitle: String {
            self == .pinyin ? "英" : "中"
        }
    }

    private enum ShiftState {
        case off
        case once
        case locked
    }

    private enum KeyAction {
        case input(String)
        case shift
        case delete
        case space
        case returnKey
        case language
        case page(KeyboardPage)
    }

    private struct KeySpec {
        let title: String?
        let systemImage: String?
        let action: KeyAction
        let width: CGFloat
        let isUtility: Bool

        init(
            _ title: String? = nil,
            systemImage: String? = nil,
            action: KeyAction,
            width: CGFloat = 1,
            isUtility: Bool = false
        ) {
            self.title = title
            self.systemImage = systemImage
            self.action = action
            self.width = width
            self.isUtility = isUtility
        }
    }

    private let rootStack = UIStackView()
    private weak var headerRow: UIView?
    private let headerLeadingContainer = UIView()
    private let appTitleButton = UIButton(type: .system)
    private let recordingModuleStack = UIStackView()
    private let phraseModuleStack = UIStackView()
    private let keyboardModuleStack = UIStackView()
    private var moduleButtons: [ContentModule: UIButton] = [:]
    private var selectedContentModule = ContentModule.voice
    private var isQuickPhraseModuleVisible = false
    private let statusLabel = UILabel()
    private var recordingButton: UIButton?
    private var recordingButtonWidthConstraint: NSLayoutConstraint?
    private var recordingButtonHeightConstraint: NSLayoutConstraint?
    private weak var recordingLevelView: KeyboardAudioLevelView?
    private var keyboardHeightConstraint: NSLayoutConstraint?
    private weak var cursorTrackingButton: UIButton?
    private var keyboardPage = KeyboardPage.letters
    private var keyboardLanguage = KeyboardLanguage.pinyin
    private var pinyinComposition = ""
    private var pinyinCandidates: [String] = []
    private weak var pinyinCandidateStack: UIStackView?
    private weak var pinyinCandidateScrollView: UIScrollView?
    private weak var pinyinCandidateExpansionButton: UIButton?
    private weak var expandedPinyinCandidateCollectionView: UICollectionView?
    private var isPinyinCandidatePanelExpanded = false
    private var hasMorePinyinCandidates = false
    private var isLoadingMorePinyinCandidates = false
    private var nextPinyinCandidateOffset = 0
    private var typingLetterButtons: [(button: UIButton, value: String)] = []
    private weak var shiftButton: UIButton?
    private var shiftState = ShiftState.off
    private var lastShiftTapAt: TimeInterval = 0
    private var deleteRepeatTimer: Timer?
    private var snapshotTimer: Timer?
    private var isCursorTracking = false
    private var cursorTrackingStartLocation = CGPoint.zero
    private var cursorTrackingDesiredOffset = 0
    private var cursorTrackingAppliedOffset = 0
    private var cursorTrackingCharactersPerLine = 24
    private var cursorTrackingDisplayLink: CADisplayLink?
    private var cursorTrackingDefaultConfiguration: UIButton.Configuration?
    private let cursorTrackingFeedbackGenerator = UIImpactFeedbackGenerator(style: .light)
    private let keyFeedbackGenerator = UIImpactFeedbackGenerator(style: .light)
    private let selectionFeedbackGenerator = UISelectionFeedbackGenerator()
    private var hapticsEnabled = true
    private var lastHandledRecognitionResultID: String?
    private var insertionMessageUntil: TimeInterval = 0
    private var appLaunchRequestedAt: TimeInterval?
    private var appOpenVerificationTask: Task<Void, Never>?
    private var recordingCommandFallbackTask: Task<Void, Never>?
    private var hostCaptureTask: Task<Void, Never>?
    private var hostPrefetchTask: Task<Void, Never>?
    private var hostPresentationStartedAt: TimeInterval?
    private var presentationHostCapture: SharedKeyboardHostCapture?
    private var launchFailureMessage: String?
    private var launchFailureMessageUntil: TimeInterval = 0
    private var hasStartedPinyinWarmup = false

    override func viewDidLoad() {
        super.viewDidLoad()
        // AgenBoard provides its own voice-input control. Telling UIKit about it
        // prevents iOS from adding a second dictation button in the bottom dock.
        hasDictationKey = true
        isQuickPhraseModuleVisible = SharedCommandStore.keyboardQuickPhraseModuleVisible()
        if let rawValue = SharedCommandStore.keyboardSelectedContentModuleRawValue(),
           let savedModule = ContentModule(rawValue: rawValue) {
            selectedContentModule = savedModule
        }
        if !isQuickPhraseModuleVisible, selectedContentModule == .phrases {
            selectedContentModule = .keyboard
            SharedCommandStore.setKeyboardSelectedContentModuleRawValue(
                ContentModule.keyboard.rawValue
            )
        }
        lastHandledRecognitionResultID = SharedCommandStore.latestRecognitionResult()?.id
        setupKeyboard()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(extensionHostDidEnterBackground),
            name: .NSExtensionHostDidEnterBackground,
            object: nil
        )
        warmPinyinEngine()
        refreshRecordingSnapshot()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func extensionHostDidEnterBackground() {
        PinyinInputEngine.suspendAndSynchronizeUserData()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        DispatchQueue.global(qos: .utility).async {
            PinyinInputEngine.prepare()
        }
        SharedCommandStore.respondToKeyboardAccessVerification(
            hasFullAccess: hasFullAccess
        )
        hapticsEnabled = SharedCommandStore.keyboardHapticsEnabled()
        refreshQuickPhraseModuleVisibility()
        reloadPhraseModule()
        prepareHostCaptureForCurrentPresentation()
        startSnapshotTimer()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        endCursorTracking(refreshSnapshot: false)
        stopDeleting()
        recordingCommandFallbackTask?.cancel()
        recordingCommandFallbackTask = nil
        hostCaptureTask?.cancel()
        hostCaptureTask = nil
        hostPrefetchTask?.cancel()
        hostPrefetchTask = nil
        finishHostCaptureForCurrentPresentation()
        stopSnapshotTimer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        // Do not leave marked text attached to a host field after the user
        // switches keyboards or dismisses this extension.
        if finalizeRawPinyinCompositionIfNeeded() {
            if isPinyinCandidatePanelExpanded {
                isPinyinCandidatePanelExpanded = false
                reloadTypingKeyboard()
            } else {
                refreshPinyinCandidateRow()
            }
        }
        PinyinInputEngine.suspendAndSynchronizeUserData()
        super.viewWillDisappear(animated)
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        updateAutomaticShiftState()
    }

    private func setupKeyboard() {
        view.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.12, green: 0.13, blue: 0.15, alpha: 1)
                : UIColor(red: 0.91, green: 0.92, blue: 0.94, alpha: 1)
        }

        rootStack.axis = .vertical
        rootStack.alignment = .fill
        rootStack.distribution = .fill
        rootStack.spacing = selectedContentModule == .keyboard ? 0 : 8
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(rootStack)

        // The candidate strip shares the header in typing mode, leaving the
        // remaining canvas to four full-height key rows.
        let keyboardHeightConstraint = view.heightAnchor.constraint(equalToConstant: 280)
        keyboardHeightConstraint.priority = UILayoutPriority(999)
        self.keyboardHeightConstraint = keyboardHeightConstraint

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -7),
            keyboardHeightConstraint
        ])

        let headerRow = makeHeaderRow()
        self.headerRow = headerRow
        rootStack.addArrangedSubview(headerRow)

        configureModuleStack(recordingModuleStack)
        configureModuleStack(phraseModuleStack)
        configureModuleStack(keyboardModuleStack)
        [recordingModuleStack, phraseModuleStack].forEach { stack in
            stack.isLayoutMarginsRelativeArrangement = true
            stack.directionalLayoutMargins = .init(
                top: 0,
                leading: 8,
                bottom: 0,
                trailing: 8
            )
        }
        rootStack.addArrangedSubview(recordingModuleStack)
        rootStack.addArrangedSubview(phraseModuleStack)
        rootStack.addArrangedSubview(keyboardModuleStack)

        setupRecordingModule()
        reloadPhraseModule()
        reloadTypingKeyboard()
        recordingModuleStack.isHidden = selectedContentModule != .voice
        phraseModuleStack.isHidden = selectedContentModule != .phrases
        keyboardModuleStack.isHidden = selectedContentModule != .keyboard
    }

    private func makeHeaderRow() -> UIView {
        appTitleButton.setTitle("AgenBoard", for: .normal)
        appTitleButton.setTitleColor(.label, for: .normal)
        appTitleButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .bold)
        appTitleButton.contentHorizontalAlignment = .leading
        appTitleButton.addTarget(self, action: #selector(openMainApp), for: .touchUpInside)
        addHapticFeedback(to: appTitleButton)
        appTitleButton.accessibilityLabel = "打开 AgenBoard 主应用"

        headerLeadingContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerLeadingContainer.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )

        let row = UIStackView(
            arrangedSubviews: [headerLeadingContainer, makeModuleSwitcher()]
        )
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = .init(top: 0, leading: 8, bottom: 0, trailing: 8)
        row.heightAnchor.constraint(equalToConstant: 42).isActive = true
        return row
    }

    private func updateHeaderLeadingContent() {
        headerLeadingContainer.subviews.forEach { $0.removeFromSuperview() }
        resetPinyinCandidateHeaderReferences()

        let content: UIView
        if selectedContentModule != .keyboard {
            content = appTitleButton
        } else {
            switch keyboardPage {
            case .letters where keyboardLanguage == .pinyin:
                content = makePinyinCandidateRow()
            case .letters:
                content = makeEnglishInputModeRow()
            case .numbers:
                content = makeKeyboardModeLabel("数字与符号")
            case .symbols:
                content = makeKeyboardModeLabel("更多符号")
            }
        }

        content.translatesAutoresizingMaskIntoConstraints = false
        headerLeadingContainer.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: headerLeadingContainer.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: headerLeadingContainer.trailingAnchor),
            content.topAnchor.constraint(equalTo: headerLeadingContainer.topAnchor),
            content.bottomAnchor.constraint(equalTo: headerLeadingContainer.bottomAnchor)
        ])
    }

    private func makeKeyboardModeLabel(_ title: String) -> UIView {
        let label = UILabel()
        label.text = title
        label.textColor = .secondaryLabel
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.isAccessibilityElement = true
        return label
    }

    private func resetPinyinCandidateHeaderReferences() {
        pinyinCandidateStack = nil
        pinyinCandidateScrollView = nil
        pinyinCandidateExpansionButton = nil
        expandedPinyinCandidateCollectionView = nil
        isLoadingMorePinyinCandidates = false
    }

    private func makeModuleSwitcher() -> UIView {
        let items: [(
            module: ContentModule,
            image: String,
            label: String,
            action: Selector
        )] = [
            (.voice, "waveform", "语音", #selector(showRecordingModule)),
            (.keyboard, "keyboard", "AgenBoard 键盘", #selector(showKeyboardModule)),
            (.phrases, "text.quote", "快捷短语", #selector(showPhraseModule))
        ]
        let symbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 16,
            weight: .semibold
        )
        let switcher = UIStackView()
        switcher.axis = .horizontal
        switcher.alignment = .center
        switcher.spacing = 0
        switcher.isLayoutMarginsRelativeArrangement = true
        switcher.directionalLayoutMargins = .init(top: 2, leading: 2, bottom: 2, trailing: 2)
        switcher.backgroundColor = .systemBackground
        switcher.layer.cornerRadius = 20
        switcher.layer.cornerCurve = .continuous
        switcher.clipsToBounds = true

        moduleButtons.removeAll()
        for item in items {
            let button = UIButton(type: .system)
            button.setImage(
                UIImage(systemName: item.image, withConfiguration: symbolConfiguration),
                for: .normal
            )
            button.tintColor = .label
            button.backgroundColor = item.module == selectedContentModule
                ? .systemGray5
                : .clear
            button.layer.cornerRadius = 18
            button.layer.cornerCurve = .continuous
            button.clipsToBounds = true
            button.addTarget(self, action: item.action, for: .touchUpInside)
            addHapticFeedback(to: button, selection: true)
            button.accessibilityLabel = item.label
            button.accessibilityTraits = item.module == selectedContentModule
                ? [.button, .selected]
                : .button
            button.isHidden = item.module == .phrases && !isQuickPhraseModuleVisible
            button.widthAnchor.constraint(equalToConstant: 34).isActive = true
            button.heightAnchor.constraint(equalToConstant: 34).isActive = true
            switcher.addArrangedSubview(button)
            moduleButtons[item.module] = button
        }

        switcher.heightAnchor.constraint(equalToConstant: 40).isActive = true
        return switcher
    }

    private func refreshQuickPhraseModuleVisibility() {
        let isVisible = SharedCommandStore.keyboardQuickPhraseModuleVisible()
        isQuickPhraseModuleVisible = isVisible
        moduleButtons[.phrases]?.isHidden = !isVisible

        if !isVisible, selectedContentModule == .phrases {
            selectContentModule(.keyboard)
        }
    }

    private func configureModuleStack(_ stack: UIStackView) {
        stack.axis = .vertical
        stack.alignment = .fill
        stack.distribution = .fill
        stack.spacing = 8
    }

    private func setupRecordingModule() {
        let canvas = UIView()
        canvas.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.text = "点击说话"
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 1
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(statusLabel)

        var recordingConfiguration = UIButton.Configuration.filled()
        recordingConfiguration.image = UIImage(systemName: "mic.fill")
        recordingConfiguration.preferredSymbolConfigurationForImage = .init(
            pointSize: 24,
            weight: .semibold
        )
        recordingConfiguration.baseBackgroundColor = .label
        recordingConfiguration.baseForegroundColor = .systemBackground
        recordingConfiguration.cornerStyle = .capsule

        let recordingButton = UIButton(configuration: recordingConfiguration)
        recordingButton.translatesAutoresizingMaskIntoConstraints = false
        recordingButton.addTarget(self, action: #selector(toggleRecording), for: .touchUpInside)
        addHapticFeedback(to: recordingButton, intensity: 0.8)
        recordingButton.accessibilityLabel = "开始语音输入"
        recordingButton.accessibilityHint = "轻点开始录音，再次轻点完成"
        canvas.addSubview(recordingButton)
        self.recordingButton = recordingButton

        let recordingLevelView = KeyboardAudioLevelView()
        recordingLevelView.translatesAutoresizingMaskIntoConstraints = false
        recordingLevelView.isUserInteractionEnabled = false
        recordingLevelView.isHidden = true
        recordingButton.addSubview(recordingLevelView)
        NSLayoutConstraint.activate([
            recordingLevelView.centerXAnchor.constraint(equalTo: recordingButton.centerXAnchor),
            recordingLevelView.centerYAnchor.constraint(equalTo: recordingButton.centerYAnchor),
            recordingLevelView.widthAnchor.constraint(equalToConstant: 58),
            recordingLevelView.heightAnchor.constraint(equalToConstant: 42)
        ])
        self.recordingLevelView = recordingLevelView

        let returnButton = makeVoiceUtilityButton(
            systemImage: "return",
            accessibilityLabel: "回车键",
            action: #selector(insertReturn),
            width: 112
        )
        let deleteButton = makeVoiceDeleteButton()
        let atButton = makeVoiceUtilityButton(
            title: "@",
            accessibilityLabel: "艾特符号",
            action: #selector(insertAtSign),
            style: .secondary
        )
        let spaceButton = makeVoiceUtilityButton(
            systemImage: "space",
            accessibilityLabel: "空格",
            action: #selector(insertSpace),
            width: 112
        )
        spaceButton.accessibilityHint = "轻点输入空格，长按并拖动可移动光标"
        configureCursorTracking(on: spaceButton)

        let textInputButtonRow = UIStackView(arrangedSubviews: [spaceButton, returnButton])
        textInputButtonRow.axis = .horizontal
        textInputButtonRow.alignment = .fill
        textInputButtonRow.distribution = .fillEqually
        textInputButtonRow.spacing = 8
        textInputButtonRow.translatesAutoresizingMaskIntoConstraints = false

        [deleteButton, atButton, textInputButtonRow].forEach(canvas.addSubview)

        let widthConstraint = recordingButton.widthAnchor.constraint(equalToConstant: 128)
        let heightConstraint = recordingButton.heightAnchor.constraint(equalToConstant: 56)
        recordingButtonWidthConstraint = widthConstraint
        recordingButtonHeightConstraint = heightConstraint

        NSLayoutConstraint.activate([
            canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: 184),
            statusLabel.topAnchor.constraint(equalTo: recordingButton.bottomAnchor, constant: 2),
            statusLabel.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: canvas.leadingAnchor, constant: 58),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: canvas.trailingAnchor, constant: -58),

            recordingButton.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            recordingButton.centerYAnchor.constraint(equalTo: canvas.topAnchor, constant: 36),
            widthConstraint,
            heightConstraint,

            textInputButtonRow.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            textInputButtonRow.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 132),
            textInputButtonRow.topAnchor.constraint(
                greaterThanOrEqualTo: statusLabel.bottomAnchor,
                constant: 2
            ),
            textInputButtonRow.bottomAnchor.constraint(
                lessThanOrEqualTo: canvas.bottomAnchor,
                constant: -10
            ),

            deleteButton.leadingAnchor.constraint(
                equalTo: textInputButtonRow.trailingAnchor,
                constant: 9
            ),
            deleteButton.centerYAnchor.constraint(
                equalTo: recordingButton.centerYAnchor,
                constant: 7
            ),
            atButton.centerXAnchor.constraint(equalTo: deleteButton.centerXAnchor),
            atButton.topAnchor.constraint(equalTo: deleteButton.bottomAnchor, constant: 8)
        ])

        recordingModuleStack.addArrangedSubview(canvas)
    }

    private func reloadPhraseModule() {
        phraseModuleStack.arrangedSubviews.forEach { view in
            phraseModuleStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let phrases = SharedCommandStore.keyboardQuickPhrases()

        if phrases.isEmpty {
            let emptyLabel = UILabel()
            emptyLabel.text = "还没有快捷短语"
            emptyLabel.textAlignment = .center
            emptyLabel.textColor = .secondaryLabel
            emptyLabel.font = .systemFont(ofSize: 14)
            phraseModuleStack.addArrangedSubview(emptyLabel)
        } else {
            for startIndex in stride(from: 0, to: phrases.count, by: 3) {
                let endIndex = min(startIndex + 3, phrases.count)
                var rowItems = phrases[startIndex..<endIndex].map {
                    phraseKey($0) as UIView
                }
                while rowItems.count < 3 {
                    let spacer = UIView()
                    rowItems.append(spacer)
                }
                phraseModuleStack.addArrangedSubview(makeCommandRow(rowItems))
            }
        }

        let flexibleSpacer = UIView()
        phraseModuleStack.addArrangedSubview(flexibleSpacer)

        let manageButton = key(
            "管理短语",
            systemImage: "text.book.closed",
            action: #selector(openPhraseLibrary)
        )
        phraseModuleStack.addArrangedSubview(manageButton)
    }

    private enum VoiceUtilityButtonStyle {
        case primary
        case secondary
    }

    private func makeVoiceUtilityButton(
        title: String? = nil,
        systemImage: String? = nil,
        accessibilityLabel: String,
        action: Selector,
        width: CGFloat = 46,
        style: VoiceUtilityButtonStyle = .primary
    ) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = systemImage.flatMap { UIImage(systemName: $0) }
        configuration.preferredSymbolConfigurationForImage = .init(
            pointSize: 17,
            weight: .medium
        )
        configuration.baseBackgroundColor = style == .primary
            ? .systemBackground
            : .systemGray5
        configuration.baseForegroundColor = .label
        configuration.cornerStyle = .capsule
        configuration.contentInsets = .zero

        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.titleLabel?.font = .systemFont(ofSize: 18, weight: .medium)
        button.addTarget(self, action: action, for: .touchUpInside)
        addHapticFeedback(to: button)
        button.accessibilityLabel = accessibilityLabel
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: width),
            button.heightAnchor.constraint(equalToConstant: 44)
        ])
        return button
    }

    private func makeVoiceDeleteButton() -> UIButton {
        let button = makeVoiceUtilityButton(
            systemImage: "delete.left",
            accessibilityLabel: "删除",
            action: #selector(stopDeleting),
            style: .secondary
        )
        button.removeTarget(self, action: #selector(stopDeleting), for: .touchUpInside)
        configureDeleteButton(button)
        return button
    }

    private func reloadTypingKeyboard() {
        endCursorTracking(refreshSnapshot: false)
        stopDeleting()
        keyboardModuleStack.arrangedSubviews.forEach { view in
            keyboardModuleStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        keyboardModuleStack.distribution = .fill
        keyboardModuleStack.spacing = 0
        resetPinyinCandidateHeaderReferences()
        typingLetterButtons.removeAll(keepingCapacity: true)
        shiftButton = nil

        let showsExpandedCandidates = isPinyinCandidatePanelExpanded
            && keyboardPage == .letters
            && keyboardLanguage == .pinyin
            && !pinyinComposition.isEmpty
        headerRow?.isHidden = showsExpandedCandidates

        if showsExpandedCandidates {
            let page = PinyinInputEngine.firstCandidatePage(
                for: pinyinComposition,
                limit: Self.pinyinCandidatePageSize
            )
            pinyinCandidates = page.candidates
            hasMorePinyinCandidates = page.hasMore
            nextPinyinCandidateOffset = page.nextOffset
            keyboardModuleStack.addArrangedSubview(makeExpandedPinyinCandidatePanel())
            return
        }

        isPinyinCandidatePanelExpanded = false
        hasMorePinyinCandidates = false
        nextPinyinCandidateOffset = 0
        headerRow?.isHidden = false
        updateHeaderLeadingContent()

        let rows: [([KeySpec], CGFloat)]
        switch keyboardPage {
        case .letters:
            let uppercase = shiftState != .off
            let rowOne = characterSpecs("qwertyuiop", uppercase: uppercase)
            let rowTwo = characterSpecs("asdfghjkl", uppercase: uppercase)
            let rowThree = [
                KeySpec(
                    systemImage: shiftState == .locked ? "capslock.fill" : "shift.fill",
                    action: .shift,
                    width: 1.45,
                    isUtility: true
                )
            ] + characterSpecs("zxcvbnm", uppercase: uppercase) + [
                KeySpec(
                    systemImage: "delete.left",
                    action: .delete,
                    width: 1.45,
                    isUtility: true
                )
            ]
            let rowFour = [
                KeySpec("123", action: .page(.numbers), width: 1.2, isUtility: true),
                KeySpec(
                    keyboardLanguage.switchTitle,
                    action: .language,
                    width: 1.05,
                    isUtility: true
                ),
                KeySpec("空格", action: .space, width: 5.65),
                KeySpec(
                    systemImage: "arrow.turn.down.left",
                    action: .returnKey,
                    width: 2.25,
                    isUtility: true
                )
            ]
            rows = [(rowOne, 0), (rowTwo, 17), (rowThree, 0), (rowFour, 0)]

        case .numbers:
            rows = [
                (characterSpecs("1234567890"), 0),
                (inputSpecs(["-", "/", ":", ";", "(", ")", "¥", "&", "@", "\""]), 0),
                ([
                    KeySpec("#+=", action: .page(.symbols), width: 1.5, isUtility: true),
                    KeySpec(".", action: .input(".")),
                    KeySpec(",", action: .input(",")),
                    KeySpec("?", action: .input("?")),
                    KeySpec("!", action: .input("!")),
                    KeySpec("'", action: .input("'")),
                    KeySpec(systemImage: "delete.left", action: .delete, width: 1.5, isUtility: true)
                ], 0),
                (bottomNonLetterRow(), 0)
            ]

        case .symbols:
            rows = [
                (inputSpecs(["[", "]", "{", "}", "#", "%", "^", "*", "+", "="]), 0),
                (inputSpecs(["_", "\\", "|", "~", "<", ">", "€", "£", "$", "•"]), 0),
                ([
                    KeySpec("123", action: .page(.numbers), width: 1.5, isUtility: true),
                    KeySpec(".", action: .input(".")),
                    KeySpec(",", action: .input(",")),
                    KeySpec("?", action: .input("?")),
                    KeySpec("!", action: .input("!")),
                    KeySpec("'", action: .input("'")),
                    KeySpec(systemImage: "delete.left", action: .delete, width: 1.5, isUtility: true)
                ], 0),
                (bottomNonLetterRow(), 0)
            ]
        }

        keyboardModuleStack.addArrangedSubview(makeTypingSurface(rows))
    }

    private func makePinyinCandidateRow() -> UIView {
        let candidateStack = UIStackView()
        candidateStack.axis = .horizontal
        candidateStack.alignment = .fill
        candidateStack.spacing = 3

        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.addSubview(candidateStack)
        candidateStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            candidateStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            candidateStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            candidateStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            candidateStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            candidateStack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        var expandConfiguration = UIButton.Configuration.plain()
        expandConfiguration.image = UIImage(systemName: "chevron.down")
        expandConfiguration.preferredSymbolConfigurationForImage = .init(
            pointSize: 14,
            weight: .semibold
        )
        expandConfiguration.baseForegroundColor = .secondaryLabel
        expandConfiguration.contentInsets = .zero
        let expandButton = UIButton(configuration: expandConfiguration)
        expandButton.addTarget(
            self,
            action: #selector(expandPinyinCandidates),
            for: .touchUpInside
        )
        addHapticFeedback(to: expandButton, selection: true)
        expandButton.accessibilityLabel = "展开更多候选词"
        expandButton.widthAnchor.constraint(equalToConstant: 32).isActive = true

        let row = UIStackView(
            arrangedSubviews: [scrollView, expandButton]
        )
        row.axis = .horizontal
        row.alignment = .fill
        row.spacing = 2
        pinyinCandidateStack = candidateStack
        pinyinCandidateScrollView = scrollView
        pinyinCandidateExpansionButton = expandButton
        refreshPinyinCandidateRow()
        return row
    }

    private func makeEnglishInputModeRow() -> UIView {
        let modeLabel = UILabel()
        modeLabel.text = "英文输入"
        modeLabel.textColor = .secondaryLabel
        modeLabel.font = .systemFont(ofSize: 14, weight: .semibold)

        let hintLabel = UILabel()
        hintLabel.text = "双击上档键锁定大写"
        hintLabel.textColor = .tertiaryLabel
        hintLabel.font = .systemFont(ofSize: 12)

        let row = UIStackView(arrangedSubviews: [modeLabel, UIView(), hintLabel])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = .init(top: 0, left: 6, bottom: 0, right: 6)
        return row
    }

    private func refreshPinyinCandidateRow() {
        guard keyboardPage == .letters,
              keyboardLanguage == .pinyin,
              let candidateStack = pinyinCandidateStack else {
            return
        }

        pinyinCandidates = PinyinInputEngine.candidates(
            for: pinyinComposition,
            limit: 48
        )

        pinyinCandidateExpansionButton?.isEnabled = !pinyinComposition.isEmpty
        pinyinCandidateExpansionButton?.alpha = pinyinComposition.isEmpty ? 0.32 : 1

        UIView.performWithoutAnimation {
            // Rebuild only the views represented by the current result set.
            // Keeping dozens of hidden arranged subviews causes UIStackView to
            // reuse stale intrinsic widths while candidates change rapidly.
            candidateStack.arrangedSubviews.forEach { view in
                candidateStack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }

            if self.pinyinComposition.isEmpty {
                let hint = UILabel()
                hint.text = "输入拼音"
                hint.textColor = .tertiaryLabel
                hint.font = .systemFont(ofSize: 13)
                candidateStack.addArrangedSubview(hint)
            } else {
                let candidates = self.pinyinCandidates.isEmpty
                    ? [(title: self.pinyinComposition, value: self.pinyinComposition)]
                    : self.pinyinCandidates.map { (title: $0, value: $0) }

                for candidate in candidates {
                    candidateStack.addArrangedSubview(
                        self.makeCandidateButton(
                            title: candidate.title,
                            value: candidate.value
                        )
                    )
                }
            }

            self.pinyinCandidateScrollView?.setContentOffset(.zero, animated: false)
            candidateStack.invalidateIntrinsicContentSize()
            candidateStack.setNeedsLayout()
            candidateStack.layoutIfNeeded()
            self.pinyinCandidateScrollView?.setNeedsLayout()
            self.pinyinCandidateScrollView?.layoutIfNeeded()
        }
    }

    private func makeCandidateButton(title: String, value: String) -> PinyinCandidateButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.baseForegroundColor = .label
        configuration.contentInsets = .init(
            top: 0,
            leading: 10,
            bottom: 0,
            trailing: 10
        )
        let button = PinyinCandidateButton(configuration: configuration)
        button.candidateValue = value
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.addTarget(self, action: #selector(selectPinyinCandidate(_:)), for: .touchUpInside)
        addHapticFeedback(to: button)
        button.accessibilityLabel = "输入候选词 \(title)"
        return button
    }

    @objc private func selectPinyinCandidate(_ button: PinyinCandidateButton) {
        commitPinyinCandidate(button.candidateValue)
    }

    private func makeExpandedPinyinCandidatePanel() -> UIView {
        if pinyinCandidates.isEmpty {
            pinyinCandidates = [pinyinComposition]
            hasMorePinyinCandidates = false
        }

        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumInteritemSpacing = 5
        layout.minimumLineSpacing = 7
        layout.sectionInset = .init(top: 3, left: 3, bottom: 4, right: 3)

        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.showsVerticalScrollIndicator = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(
            PinyinCandidateCollectionCell.self,
            forCellWithReuseIdentifier: Self.pinyinCandidateCellIdentifier
        )
        expandedPinyinCandidateCollectionView = collectionView
        return collectionView
    }

    func collectionView(
        _ collectionView: UICollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        max(6, pinyinCandidates.count + 1)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: Self.pinyinCandidateCellIdentifier,
            for: indexPath
        ) as! PinyinCandidateCollectionCell

        if indexPath.item == 5 {
            cell.configureAsCollapseButton()
        } else if let candidateIndex = expandedCandidateIndex(for: indexPath.item) {
            cell.configure(
                title: pinyinCandidates[candidateIndex],
                isPrimary: candidateIndex == 0
            )
        } else {
            cell.configureAsPlaceholder()
        }
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        didSelectItemAt indexPath: IndexPath
    ) {
        if hapticsEnabled {
            keyFeedbackGenerator.prepare()
            keyFeedbackGenerator.impactOccurred(intensity: 0.5)
        }

        if indexPath.item == 5 {
            collapsePinyinCandidates()
        } else if let candidateIndex = expandedCandidateIndex(for: indexPath.item) {
            commitPinyinCandidate(pinyinCandidates[candidateIndex])
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        shouldSelectItemAt indexPath: IndexPath
    ) -> Bool {
        indexPath.item == 5 || expandedCandidateIndex(for: indexPath.item) != nil
    }

    func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard let candidateIndex = expandedCandidateIndex(for: indexPath.item),
              candidateIndex >= pinyinCandidates.count - 6 else {
            return
        }
        loadMorePinyinCandidatesIfNeeded()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === expandedPinyinCandidateCollectionView,
              scrollView.contentSize.height > 0 else {
            return
        }
        let distanceToBottom = scrollView.contentSize.height
            - scrollView.contentOffset.y
            - scrollView.bounds.height
        if distanceToBottom < 86 {
            loadMorePinyinCandidatesIfNeeded()
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let horizontalInsets: CGFloat = 6
        let totalSpacing: CGFloat = 25
        let width = floor(
            (collectionView.bounds.width - horizontalInsets - totalSpacing) / 6
        )
        return CGSize(width: max(1, width), height: 43)
    }

    private func expandedCandidateIndex(for itemIndex: Int) -> Int? {
        let candidateIndex = itemIndex < 5 ? itemIndex : itemIndex - 1
        guard itemIndex != 5,
              pinyinCandidates.indices.contains(candidateIndex) else {
            return nil
        }
        return candidateIndex
    }

    private func loadMorePinyinCandidatesIfNeeded() {
        guard isPinyinCandidatePanelExpanded,
              hasMorePinyinCandidates,
              !isLoadingMorePinyinCandidates,
              let collectionView = expandedPinyinCandidateCollectionView else {
            return
        }

        isLoadingMorePinyinCandidates = true
        let page = PinyinInputEngine.nextCandidatePage(
            for: pinyinComposition,
            offset: nextPinyinCandidateOffset,
            limit: Self.pinyinCandidatePageSize
        )
        var seen = Set(pinyinCandidates)
        let newCandidates = page.candidates.filter { seen.insert($0).inserted }
        pinyinCandidates.append(contentsOf: newCandidates)
        hasMorePinyinCandidates = page.hasMore
        nextPinyinCandidateOffset = page.nextOffset
        isLoadingMorePinyinCandidates = false
        collectionView.reloadData()
    }

    private func characterSpecs(
        _ characters: String,
        uppercase: Bool = false
    ) -> [KeySpec] {
        characters.map { character in
            let value = String(character)
            return KeySpec(
                uppercase ? value.uppercased() : value,
                action: .input(value)
            )
        }
    }

    private func inputSpecs(_ values: [String]) -> [KeySpec] {
        values.map { KeySpec($0, action: .input($0)) }
    }

    private func bottomNonLetterRow() -> [KeySpec] {
        [
            KeySpec("ABC", action: .page(.letters), width: 1.35, isUtility: true),
            KeySpec("空格", action: .space, width: 6.45),
            KeySpec(
                systemImage: "arrow.turn.down.left",
                action: .returnKey,
                width: 1.55,
                isUtility: true
            )
        ]
    }

    private func makeTypingSurface(
        _ rows: [([KeySpec], CGFloat)]
    ) -> KeyboardTypingSurfaceView {
        let surface = KeyboardTypingSurfaceView()
        surface.translatesAutoresizingMaskIntoConstraints = false

        var spaceButton: UIButton?
        for (specs, sideInset) in rows {
            let row = makeTypingRow(specs, sideInset: sideInset + 8)
            surface.addRow(row.view, buttons: row.buttons)

            for (spec, button) in zip(specs, row.buttons) {
                if case .space = spec.action {
                    spaceButton = button
                }
            }
        }

        surface.cursorTrackingButton = spaceButton
        surface.onCursorTrackingBegan = { [weak self, weak surface] button, point in
            guard let self, let surface else {
                return
            }
            self.beginCursorTracking(on: button, at: self.view.convert(point, from: surface))
        }
        surface.onCursorTrackingChanged = { [weak self, weak surface] point in
            guard let self, let surface else {
                return
            }
            self.updateCursorTracking(at: self.view.convert(point, from: surface))
        }
        surface.onCursorTrackingEnded = { [weak self, weak surface] point in
            guard let self, let surface else {
                return
            }
            self.updateCursorTracking(at: self.view.convert(point, from: surface))
            self.endCursorTracking()
        }
        return surface
    }

    private func makeTypingRow(
        _ specs: [KeySpec],
        sideInset: CGFloat
    ) -> (view: UIView, buttons: [UIButton]) {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.distribution = .fill
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false

        let buttons = specs.map(makeTypingKey)
        buttons.forEach(stack.addArrangedSubview)

        if let referenceButton = buttons.first,
           let referenceWidth = specs.first?.width {
            for (button, spec) in zip(buttons.dropFirst(), specs.dropFirst()) {
                let constraint = button.widthAnchor.constraint(
                    equalTo: referenceButton.widthAnchor,
                    multiplier: spec.width / referenceWidth
                )
                constraint.isActive = true
            }
        }

        let wrapper = UIView()
        wrapper.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: sideInset),
            stack.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -sideInset),
            stack.topAnchor.constraint(equalTo: wrapper.topAnchor),
            stack.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor)
        ])
        return (wrapper, buttons)
    }

    private func makeTypingKey(_ spec: KeySpec) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = spec.title
        configuration.image = spec.systemImage.flatMap { UIImage(systemName: $0) }
        configuration.preferredSymbolConfigurationForImage = .init(
            pointSize: 16,
            weight: .medium
        )
        configuration.baseBackgroundColor = spec.isUtility ? .systemGray4 : .systemBackground
        configuration.baseForegroundColor = .label
        configuration.cornerStyle = .medium
        configuration.contentInsets = .zero

        if case .shift = spec.action, shiftState != .off {
            configuration.baseBackgroundColor = .label
            configuration.baseForegroundColor = .systemBackground
        }

        let button = UIButton(configuration: configuration)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .regular)
        button.titleLabel?.numberOfLines = 1
        button.titleLabel?.lineBreakMode = .byClipping
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.82
        addHapticFeedback(to: button)

        switch spec.action {
        case .input(let value):
            button.addAction(
                UIAction { [weak self] _ in self?.insertTypingInput(value) },
                for: .touchUpInside
            )
            button.accessibilityLabel = value
            if keyboardPage == .letters {
                typingLetterButtons.append((button, value))
            }

        case .shift:
            button.addTarget(self, action: #selector(toggleShift), for: .touchUpInside)
            button.accessibilityLabel = shiftState == .locked ? "关闭大写锁定" : "大写"
            button.accessibilityValue = shiftState == .locked ? "已锁定" : nil
            shiftButton = button

        case .delete:
            configureDeleteButton(button)

        case .space:
            button.addTarget(self, action: #selector(insertSpace), for: .touchUpInside)
            button.accessibilityLabel = "空格"
            button.accessibilityHint = "轻点输入空格，长按并拖动可移动光标"
            configureCursorTracking(on: button)

        case .returnKey:
            button.addTarget(self, action: #selector(insertReturn), for: .touchUpInside)
            button.accessibilityLabel = "换行"

        case .language:
            button.addTarget(self, action: #selector(toggleKeyboardLanguage), for: .touchUpInside)
            button.accessibilityLabel = keyboardLanguage == .pinyin
                ? "切换到英文输入"
                : "切换到拼音输入"

        case .page(let page):
            button.addAction(
                UIAction { [weak self] _ in self?.showKeyboardPage(page) },
                for: .touchUpInside
            )
            button.accessibilityLabel = spec.title
        }

        return button
    }

    private func refreshShiftAppearance() {
        guard keyboardPage == .letters else {
            return
        }

        let uppercase = shiftState != .off
        for (button, value) in typingLetterButtons {
            var configuration = button.configuration
            configuration?.title = uppercase ? value.uppercased() : value.lowercased()
            button.configuration = configuration
            button.accessibilityLabel = uppercase ? value.uppercased() : value.lowercased()
        }

        if let shiftButton {
            var configuration = shiftButton.configuration
            configuration?.image = UIImage(
                systemName: shiftState == .locked ? "capslock.fill" : "shift.fill"
            )
            configuration?.baseBackgroundColor = shiftState == .off
                ? .systemGray4
                : .label
            configuration?.baseForegroundColor = shiftState == .off
                ? .label
                : .systemBackground
            shiftButton.configuration = configuration
            shiftButton.accessibilityLabel = shiftState == .locked
                ? "关闭大写锁定"
                : "大写"
            shiftButton.accessibilityValue = shiftState == .locked ? "已锁定" : nil
        }
    }

    private func configureCursorTracking(on button: UIButton) {
        let gesture = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleSpaceCursorTracking(_:))
        )
        gesture.minimumPressDuration = 0.3
        gesture.allowableMovement = .greatestFiniteMagnitude
        gesture.cancelsTouchesInView = true
        button.addGestureRecognizer(gesture)
    }

    private func configureDeleteButton(_ button: UIButton) {
        button.addTarget(self, action: #selector(startDeleting), for: .touchDown)
        button.addTarget(
            self,
            action: #selector(stopDeleting),
            for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit]
        )
        button.accessibilityLabel = "删除"
    }

    private func makeCommandRow(_ views: [UIView]) -> UIStackView {
        let row = UIStackView(arrangedSubviews: views)
        row.axis = .horizontal
        row.alignment = .fill
        row.distribution = .fillEqually
        row.spacing = 8
        return row
    }

    private func key(_ title: String, systemImage: String? = nil, action: Selector) -> UIButton {
        let button = configuredKey(title, systemImage: systemImage)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func phraseKey(_ phrase: SharedQuickPhrase) -> UIButton {
        let button = configuredKey(phrase.title, systemImage: nil)
        button.addAction(
            UIAction { [weak self] _ in
                self?.insert(phrase.content)
            },
            for: .touchUpInside
        )
        button.accessibilityLabel = "插入 \(phrase.title)"
        button.accessibilityValue = phrase.content
        return button
    }

    private func configuredKey(_ title: String, systemImage: String?) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = systemImage.flatMap { UIImage(systemName: $0) }
        configuration.imagePadding = 6
        configuration.baseBackgroundColor = .systemBackground
        configuration.baseForegroundColor = .label
        configuration.cornerStyle = .medium

        let button = UIButton(configuration: configuration)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        addHapticFeedback(to: button)
        return button
    }

    private func addHapticFeedback(
        to button: UIButton,
        selection: Bool = false,
        intensity: CGFloat = 0.5
    ) {
        let action = UIAction { [weak self] _ in
            guard let self, self.hapticsEnabled else {
                return
            }

            if selection {
                self.selectionFeedbackGenerator.prepare()
                self.selectionFeedbackGenerator.selectionChanged()
            } else {
                self.keyFeedbackGenerator.prepare()
                self.keyFeedbackGenerator.impactOccurred(intensity: intensity)
            }
        }
        button.addAction(action, for: .touchDown)
    }

    private func insert(_ text: String) {
        textDocumentProxy.insertText(text)
    }

    @objc private func showRecordingModule() {
        selectContentModule(.voice)
    }

    @objc private func showPhraseModule() {
        guard isQuickPhraseModuleVisible else {
            return
        }
        selectContentModule(.phrases)
        reloadPhraseModule()
    }

    @objc private func showKeyboardModule() {
        selectContentModule(.keyboard)
        updateAutomaticShiftState()
    }

    private func selectContentModule(_ module: ContentModule) {
        if selectedContentModule == .keyboard, module != .keyboard,
           commitBestPinyinCandidateIfNeeded() {
            refreshPinyinCandidateRow()
        }
        endCursorTracking(refreshSnapshot: false)
        stopDeleting()
        if module != .keyboard {
            isPinyinCandidatePanelExpanded = false
            headerRow?.isHidden = false
        }
        selectedContentModule = module
        rootStack.spacing = module == .keyboard ? 0 : 8
        SharedCommandStore.setKeyboardSelectedContentModuleRawValue(module.rawValue)
        recordingModuleStack.isHidden = module != .voice
        phraseModuleStack.isHidden = module != .phrases
        keyboardModuleStack.isHidden = module != .keyboard

        if module == .keyboard {
            reloadTypingKeyboard()
        } else {
            updateHeaderLeadingContent()
        }

        for (buttonModule, button) in moduleButtons {
            let isSelected = buttonModule == module
            button.accessibilityTraits = isSelected
                ? [.button, .selected]
                : .button
            UIView.animate(withDuration: 0.16) {
                button.backgroundColor = isSelected
                    ? .systemGray5
                    : .clear
            }
        }
    }

    private func warmPinyinEngine() {
        guard !hasStartedPinyinWarmup else {
            return
        }
        hasStartedPinyinWarmup = true
        DispatchQueue.global(qos: .utility).async {
            PinyinInputEngine.prepare()
        }
    }

    private func insertTypingInput(_ text: String) {
        let output = keyboardPage == .letters && shiftState != .off
            ? text.uppercased()
            : text

        if keyboardPage == .letters, keyboardLanguage == .pinyin {
            pinyinComposition.append(contentsOf: output)
            updateMarkedPinyinComposition()
            refreshPinyinCandidateRow()
        } else {
            insert(output)
        }
        lastShiftTapAt = 0

        if shiftState == .once {
            shiftState = .off
            refreshShiftAppearance()
        }
    }

    private func showKeyboardPage(_ page: KeyboardPage) {
        stopDeleting()
        endCursorTracking(refreshSnapshot: false)
        if keyboardPage == .letters, page != .letters {
            commitBestPinyinCandidateIfNeeded()
        }
        keyboardPage = page
        lastShiftTapAt = 0
        shiftState = page == .letters && keyboardLanguage == .english
            ? automaticShiftState()
            : .off
        reloadTypingKeyboard()
    }

    @objc private func toggleKeyboardLanguage() {
        stopDeleting()
        endCursorTracking(refreshSnapshot: false)
        // Switching to English keeps the visible Latin composition instead of
        // implicitly accepting the first Chinese candidate.
        finalizeRawPinyinCompositionIfNeeded()
        keyboardLanguage = keyboardLanguage == .pinyin ? .english : .pinyin
        lastShiftTapAt = 0
        shiftState = keyboardLanguage == .english ? automaticShiftState() : .off
        reloadTypingKeyboard()
    }

    @objc private func commitRawPinyinComposition() {
        if finalizeRawPinyinCompositionIfNeeded() {
            refreshPinyinCandidateRow()
        }
    }

    @objc private func expandPinyinCandidates() {
        guard keyboardPage == .letters,
              keyboardLanguage == .pinyin,
              !pinyinComposition.isEmpty else {
            return
        }
        isPinyinCandidatePanelExpanded = true
        reloadTypingKeyboard()
    }

    @objc private func collapsePinyinCandidates() {
        guard isPinyinCandidatePanelExpanded else {
            return
        }
        isPinyinCandidatePanelExpanded = false
        reloadTypingKeyboard()
    }

    private func commitPinyinCandidate(_ candidate: String) {
        guard !pinyinComposition.isEmpty else {
            return
        }
        let selection = PinyinInputEngine.selection(
            for: candidate,
            composition: pinyinComposition
        ) ?? .committed(candidate)
        switch selection {
        case let .committed(text):
            replaceMarkedPinyinComposition(with: text)
        case let .composing(markedText):
            textDocumentProxy.setMarkedText(
                markedText,
                selectedRange: NSRange(
                    location: markedText.utf16.count,
                    length: 0
                )
            )
            pinyinCandidates = []
        }
        if isPinyinCandidatePanelExpanded {
            isPinyinCandidatePanelExpanded = false
            reloadTypingKeyboard()
        } else {
            refreshPinyinCandidateRow()
        }
    }

    @discardableResult
    private func commitBestPinyinCandidateIfNeeded() -> Bool {
        guard keyboardLanguage == .pinyin,
              keyboardPage == .letters,
              !pinyinComposition.isEmpty else {
            return false
        }

        let value = pinyinCandidates.first
            ?? PinyinInputEngine.candidates(for: pinyinComposition, limit: 1).first
            ?? pinyinComposition
        let selectedText = PinyinInputEngine.selectedText(
            for: value,
            composition: pinyinComposition
        ) ?? value
        replaceMarkedPinyinComposition(with: selectedText)
        return true
    }

    private func updateMarkedPinyinComposition() {
        let markedText = PinyinInputEngine.markedText(for: pinyinComposition)
        textDocumentProxy.setMarkedText(
            markedText,
            selectedRange: NSRange(location: markedText.utf16.count, length: 0)
        )
    }

    private func replaceMarkedPinyinComposition(with text: String) {
        textDocumentProxy.setMarkedText(
            text,
            selectedRange: NSRange(location: text.utf16.count, length: 0)
        )
        textDocumentProxy.unmarkText()
        pinyinComposition = ""
        pinyinCandidates = []
        PinyinInputEngine.resetComposition()
    }

    @discardableResult
    private func finalizeRawPinyinCompositionIfNeeded() -> Bool {
        guard keyboardLanguage == .pinyin,
              keyboardPage == .letters,
              !pinyinComposition.isEmpty else {
            return false
        }

        textDocumentProxy.unmarkText()
        pinyinComposition = ""
        pinyinCandidates = []
        PinyinInputEngine.resetComposition()
        return true
    }

    @objc private func toggleShift() {
        let now = Date().timeIntervalSince1970
        if shiftState == .locked {
            shiftState = .off
            lastShiftTapAt = 0
        } else if now - lastShiftTapAt < 0.4 {
            shiftState = .locked
            lastShiftTapAt = 0
        } else {
            shiftState = shiftState == .off ? .once : .off
            lastShiftTapAt = now
        }
        refreshShiftAppearance()
    }

    private func updateAutomaticShiftState() {
        guard selectedContentModule == .keyboard,
              keyboardPage == .letters,
              keyboardLanguage == .english,
              shiftState != .locked else {
            return
        }

        let desiredState = automaticShiftState()
        guard desiredState != shiftState else {
            return
        }
        shiftState = desiredState
        lastShiftTapAt = 0
        refreshShiftAppearance()
    }

    private func automaticShiftState() -> ShiftState {
        guard let context = textDocumentProxy.documentContextBeforeInput,
              !context.isEmpty else {
            return .once
        }

        let trimmed = context.reversed()
            .drop(while: { $0 == " " || $0 == "\t" })
        guard let lastCharacter = trimmed.first else {
            return .once
        }
        return lastCharacter == "\n" || ".!?。！？".contains(lastCharacter)
            ? .once
            : .off
    }

    @objc private func openMainApp() {
        openContainingApp(URL(string: "agenboard://open"), reason: "open_main_app")
    }

    @objc private func openPhraseLibrary() {
        openContainingApp(URL(string: "agenboard://phrases"), reason: "open_phrase_library")
    }

    @objc private func toggleRecording() {
        guard recordingCommandFallbackTask == nil,
              hostCaptureTask == nil else {
            return
        }

        launchFailureMessage = nil
        launchFailureMessageUntil = 0
        let snapshot = SharedCommandStore.latestRecordingSnapshot()
        let now = Date().timeIntervalSince1970
        let snapshotAge = now - snapshot.updatedAt
        let isAppResponsive = snapshotAge >= -0.5 && snapshotAge < 1.5
        let canUseBackgroundCommand = isAppResponsive
            && (snapshot.isRecording || snapshot.isBackgroundStartReady)
        let diagnosticState = String(
            format: "age=%.3f recording=%d transcribing=%d background_ready=%d",
            snapshotAge,
            snapshot.isRecording ? 1 : 0,
            snapshot.isTranscribing ? 1 : 0,
            snapshot.isBackgroundStartReady ? 1 : 0
        )
        SharedCommandStore.recordKeyboardDiagnostic(
            "recording_button_tapped",
            detail: diagnosticState
        )
        RecordingLaunchMetrics.mark(
            "keyboard_recording_button_tapped",
            requestedAt: now,
            detail: diagnosticState
        )
        lastHandledRecognitionResultID = SharedCommandStore.latestRecognitionResult()?.id
            ?? lastHandledRecognitionResultID

        if canUseBackgroundCommand {
            // Prefer the invisible App-Group path while PiP keeps the containing
            // app responsive. If the command is not acknowledged or completed,
            // verification below falls back to the foreground with the same ID.
            let command: SharedRecordingCommand = snapshot.isRecording ? .stop : .start
            if let request = SharedCommandStore.requestRecordingCommand(
                command,
                requiresForegroundRoundTrip: false
            ) {
                RecordingLaunchMetrics.mark(
                    "keyboard_live_request_persisted",
                    request: request
                )
                SharedCommandStore.recordKeyboardDiagnostic(
                    "responsive_app_group_request",
                    detail: "id=\(request.id) \(diagnosticState)"
                )
                statusLabel.text = snapshot.isRecording
                    ? "正在停止录音..."
                    : "已发送录音请求"
                scheduleRecordingCommandFallback(for: request)
            } else {
                SharedCommandStore.recordKeyboardDiagnostic(
                    "responsive_app_group_request_failed",
                    detail: diagnosticState
                )
                showLaunchFailure("共享通道不可用，请重新启用完整访问")
            }
            return
        }

        SharedCommandStore.recordKeyboardDiagnostic(
            "cold_app_manual_round_trip_started",
            detail: diagnosticState
        )
        statusLabel.text = "正在识别刚才的 App..."
        hostCaptureTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let sourceHost = await self.captureHostForCurrentRecordingTap()
            guard !Task.isCancelled else {
                self.hostCaptureTask = nil
                return
            }

            if let sourceHost {
                SharedCommandStore.recordKeyboardDiagnostic(
                    "host_bundle_captured_for_request",
                    detail: "bundle=\(sourceHost.bundleIdentifier) generation=\(sourceHost.generation) kind=\(sourceHost.kind.rawValue)"
                )
            } else {
                SharedCommandStore.recordKeyboardDiagnostic(
                    "host_bundle_capture_timed_out",
                    detail: "single_refresh"
                )
            }

            self.persistColdRecordingRequest(
                sourceHost: sourceHost,
                fallbackRequestedAt: now
            )
            self.hostCaptureTask = nil
        }
    }

    @MainActor
    private func captureHostForCurrentRecordingTap() async -> SharedKeyboardHostCapture? {
        if let presentationHostCapture {
            SharedCommandStore.markKeyboardHostCaptureConsumed(
                presentationHostCapture
            )
            return presentationHostCapture
        }

        guard let presentationStartedAt = hostPresentationStartedAt else {
            SharedCommandStore.recordKeyboardDiagnostic(
                "host_capture_attempt_missing",
                detail: "view_did_appear_not_prepared"
            )
            return nil
        }

        // If the user taps quickly, let the already-running presentation
        // prefetch finish instead of starting a competing refresh sequence.
        if let prefetchTask = hostPrefetchTask {
            await prefetchTask.value
            hostPrefetchTask = nil
            if let presentationHostCapture {
                SharedCommandStore.markKeyboardHostCaptureConsumed(
                    presentationHostCapture
                )
                return presentationHostCapture
            }
        }

        if let capture = consumeLatestHostCapture(
            presentationStartedAt: presentationStartedAt
        ) {
            return capture
        }

        // The old working branch used a refresh burst while the keyboard was
        // visible. Keep a shorter final burst for a tap that raced presentation.
        if #available(iOS 26.4, *) {
            for attempt in 1...6 {
                let didRequestRefresh = refreshHostBundleIdentifierUsingArbiterOnce()
                if let capture = consumeLatestHostCapture(
                    presentationStartedAt: presentationStartedAt
                ) {
                    SharedCommandStore.recordKeyboardDiagnostic(
                        "host_capture_tap_refresh_ready",
                        detail: "attempt=\(attempt) bundle=\(capture.bundleIdentifier)"
                    )
                    return capture
                }

                guard didRequestRefresh else {
                    break
                }
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    return nil
                }
            }
        }
        return nil
    }

    private func prepareHostCaptureForCurrentPresentation() {
        guard hostPresentationStartedAt == nil else {
            return
        }

        let presentationStartedAt = Date().timeIntervalSince1970
        hostPresentationStartedAt = presentationStartedAt
        presentationHostCapture = nil

        // +load may receive the destination before viewDidAppear. Preserve and
        // consume that fresh callback instead of deleting it here.
        if let capture = SharedCommandStore.latestUnconsumedKeyboardHostCapture(
            presentationStartedAt: presentationStartedAt
        ) {
            presentationHostCapture = capture
            SharedCommandStore.recordKeyboardDiagnostic(
                "host_bundle_captured_before_view_did_appear",
                detail: "bundle=\(capture.bundleIdentifier) generation=\(capture.generation)"
            )
            return
        }

        if #available(iOS 26.4, *) {
            startHostCapturePrefetch(
                presentationStartedAt: presentationStartedAt
            )
            return
        }

        guard let bundleIdentifier = LegacyKeyboardHostResolver.resolve(from: self) else {
            SharedCommandStore.recordKeyboardDiagnostic(
                "host_bundle_capture_failed",
                detail: "legacy resolver returned nil"
            )
            return
        }
        presentationHostCapture = SharedKeyboardHostCapture(
            bundleIdentifier: bundleIdentifier,
            capturedAt: Date().timeIntervalSince1970,
            generation: UUID().uuidString,
            kind: SharedCommandStore.hostKind(for: bundleIdentifier)
        )
        SharedCommandStore.recordKeyboardDiagnostic(
            "host_bundle_captured",
            detail: bundleIdentifier
        )
    }

    private func startHostCapturePrefetch(
        presentationStartedAt: TimeInterval
    ) {
        hostPrefetchTask?.cancel()
        hostPrefetchTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            // Preserve the exact retry budget of the previously working branch
            // for this A/B test. It stops immediately when a callback arrives.
            for attempt in 1...10 {
                guard !Task.isCancelled,
                      self.hostPresentationStartedAt == presentationStartedAt else {
                    return
                }

                let didRequestRefresh = self.refreshHostBundleIdentifierUsingArbiterOnce()

                if let capture = self.consumeLatestHostCapture(
                    presentationStartedAt: presentationStartedAt
                ) {
                    SharedCommandStore.recordKeyboardDiagnostic(
                        "host_capture_prefetch_ready",
                        detail: "attempt=\(attempt) bundle=\(capture.bundleIdentifier)"
                    )
                    self.hostPrefetchTask = nil
                    return
                }

                guard didRequestRefresh else {
                    break
                }
                do {
                    try await Task.sleep(nanoseconds: 75_000_000)
                } catch {
                    return
                }
            }

            if let capture = self.consumeLatestHostCapture(
                presentationStartedAt: presentationStartedAt
            ) {
                SharedCommandStore.recordKeyboardDiagnostic(
                    "host_capture_prefetch_ready",
                    detail: "attempt=final bundle=\(capture.bundleIdentifier)"
                )
            } else {
                SharedCommandStore.recordKeyboardDiagnostic(
                    "host_capture_prefetch_timed_out",
                    detail: "attempts=10"
                )
            }
            self.hostPrefetchTask = nil
        }
    }

    private func finishHostCaptureForCurrentPresentation() {
        if let presentationHostCapture {
            SharedCommandStore.markKeyboardHostCaptureConsumed(
                presentationHostCapture
            )
        }
        if let hostPresentationStartedAt,
           let lateCapture = SharedCommandStore.latestUnconsumedKeyboardHostCapture(
               presentationStartedAt: hostPresentationStartedAt
           ) {
            // Even when no recording was requested, do not leak a callback from
            // this presentation into the next host application.
            SharedCommandStore.markKeyboardHostCaptureConsumed(lateCapture)
        }
        hostPresentationStartedAt = nil
        presentationHostCapture = nil
    }

    private func consumeLatestHostCapture(
        presentationStartedAt: TimeInterval
    ) -> SharedKeyboardHostCapture? {
        guard let capture = SharedCommandStore.latestUnconsumedKeyboardHostCapture(
            presentationStartedAt: presentationStartedAt
        ) else {
            return nil
        }

        presentationHostCapture = capture
        SharedCommandStore.markKeyboardHostCaptureConsumed(capture)
        return capture
    }

    private func refreshHostBundleIdentifierUsingArbiterOnce() -> Bool {
        let selector = NSSelectorFromString("refreshHostBundleIdentifierOnce")
        guard let trackerClass = NSClassFromString("KeyboardHostTracker"),
              let method = class_getClassMethod(trackerClass, selector) else {
            SharedCommandStore.recordKeyboardDiagnostic(
                "host_tracker_refresh_unavailable",
                detail: "class_or_selector_missing"
            )
            return false
        }

        typealias RefreshImplementation = @convention(c) (
            AnyObject,
            Selector
        ) -> Void
        let refresh = unsafeBitCast(
            method_getImplementation(method),
            to: RefreshImplementation.self
        )
        refresh(trackerClass, selector)
        return true
    }

    private func persistColdRecordingRequest(
        sourceHost: SharedKeyboardHostCapture?,
        fallbackRequestedAt: TimeInterval
    ) {
        if let request = SharedCommandStore.requestRecordingCommand(
            .start,
            requiresForegroundRoundTrip: true,
            sourceHost: sourceHost
        ) {
            RecordingLaunchMetrics.mark(
                "keyboard_cold_request_persisted",
                request: request,
                detail: sourceHost?.bundleIdentifier ?? "host_unavailable"
            )
            appLaunchRequestedAt = request.requestedAt
            statusLabel.text = "正在打开 AgenBoard 并启动录音..."
            openContainingApp(
                recordingURL(for: request),
                reason: "cold_snapshot",
                request: request
            )
        } else {
            appLaunchRequestedAt = fallbackRequestedAt
            statusLabel.text = "共享通道不可用，正在打开 AgenBoard..."
            openContainingApp(
                URL(string: "agenboard://record?manualReturn=1&command=start"),
                reason: "cold_shared_request_failed"
            )
        }
    }

    private func startSnapshotTimer() {
        snapshotTimer?.invalidate()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshRecordingSnapshot()
            }
        }

        snapshotTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopSnapshotTimer() {
        snapshotTimer?.invalidate()
        snapshotTimer = nil
    }

    private func refreshRecordingSnapshot() {
        guard !isCursorTracking else {
            return
        }

        let snapshot = SharedCommandStore.latestRecordingSnapshot()
        let now = Date().timeIntervalSince1970
        let isFresh = now - snapshot.updatedAt < 1.5
        let isActive = isFresh && snapshot.isRecording
        let isTranscribing = isFresh && snapshot.isTranscribing
        let shouldKeepInsertionMessage = now < insertionMessageUntil
        let shouldShowLaunchFailure = now < launchFailureMessageUntil
        let isLaunchingApp = appLaunchRequestedAt.map { now - $0 < 8 } ?? false
        let isAwaitingRecordingCommand = recordingCommandFallbackTask != nil
            || hostCaptureTask != nil
        let snapshotError = isFresh ? voiceErrorMessage(from: snapshot.status) : nil

        if isFresh {
            appLaunchRequestedAt = nil
        }

        updateRecordingButton(
            isRecording: isActive,
            isTranscribing: isTranscribing,
            isLaunchingApp: (isLaunchingApp && !isFresh)
                || isAwaitingRecordingCommand,
            audioLevel: isActive ? snapshot.audioLevel : 0
        )

        if shouldKeepInsertionMessage {
            statusLabel.textColor = .systemGreen
        } else if shouldShowLaunchFailure, let launchFailureMessage {
            statusLabel.text = launchFailureMessage
            statusLabel.textColor = .systemRed
        } else if isActive {
            statusLabel.text = "再次点击完成"
            statusLabel.textColor = .secondaryLabel
        } else if isTranscribing {
            statusLabel.textColor = .secondaryLabel
            statusLabel.text = nil
        } else if isLaunchingApp || isAwaitingRecordingCommand {
            statusLabel.text = nil
            statusLabel.textColor = .secondaryLabel
        } else if let snapshotError {
            statusLabel.text = snapshotError
            statusLabel.textColor = .systemRed
        } else {
            statusLabel.text = "点击说话"
            statusLabel.textColor = .secondaryLabel
        }

        insertRecognitionResultIfNeeded(isRecording: isActive, isTranscribing: isTranscribing, now: now)
    }

    private func voiceErrorMessage(from status: String) -> String? {
        let errorMarkers = ["失败", "错误", "权限", "未授权", "拒绝", "不允许", "不可用"]
        guard errorMarkers.contains(where: status.contains) else {
            return nil
        }
        return status.count <= 24 ? status : "语音输入失败，请重试"
    }

    private func updateRecordingButton(
        isRecording: Bool,
        isTranscribing: Bool,
        isLaunchingApp: Bool,
        audioLevel: Double
    ) {
        guard let recordingButton else {
            return
        }

        var configuration = recordingButton.configuration
        var targetWidth: CGFloat
        var targetHeight: CGFloat

        if isRecording {
            configuration?.title = nil
            configuration?.image = nil
            configuration?.baseBackgroundColor = .label
            configuration?.baseForegroundColor = .systemBackground
            targetWidth = 104
            targetHeight = 104
            recordingButton.isEnabled = true
            recordingButton.accessibilityLabel = "完成语音输入"
        } else if isTranscribing {
            configuration?.title = "正在处理…"
            configuration?.image = nil
            configuration?.baseBackgroundColor = .systemGray3
            configuration?.baseForegroundColor = .label
            targetWidth = 112
            targetHeight = 44
            recordingButton.isEnabled = false
            recordingButton.accessibilityLabel = "正在处理语音"
        } else if isLaunchingApp {
            configuration?.title = "正在启动…"
            configuration?.image = nil
            configuration?.baseBackgroundColor = .systemGray3
            configuration?.baseForegroundColor = .label
            targetWidth = 112
            targetHeight = 44
            recordingButton.isEnabled = false
            recordingButton.accessibilityLabel = "正在启动语音输入"
        } else {
            configuration?.title = nil
            configuration?.image = UIImage(systemName: "mic.fill")
            configuration?.baseBackgroundColor = .label
            configuration?.baseForegroundColor = .systemBackground
            targetWidth = 128
            targetHeight = 56
            recordingButton.isEnabled = true
            recordingButton.accessibilityLabel = "开始语音输入"
        }

        recordingButton.configuration = configuration
        recordingLevelView?.isHidden = !isRecording
        recordingLevelView?.update(level: audioLevel, isActive: isRecording)
        if isRecording, let recordingLevelView {
            recordingButton.bringSubviewToFront(recordingLevelView)
        }
        updateRecordingButtonSize(width: targetWidth, height: targetHeight)
    }

    private func updateRecordingButtonSize(width: CGFloat, height: CGFloat) {
        guard let widthConstraint = recordingButtonWidthConstraint,
              let heightConstraint = recordingButtonHeightConstraint,
              widthConstraint.constant != width || heightConstraint.constant != height else {
            return
        }

        widthConstraint.constant = width
        heightConstraint.constant = height
        UIView.animate(
            withDuration: 0.2,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
        ) {
            self.view.layoutIfNeeded()
        }
    }

    private func recordingURL(for request: SharedRecordingToggleRequest) -> URL? {
        var components = URLComponents()
        components.scheme = "agenboard"
        components.host = "record"
        components.queryItems = [
            URLQueryItem(name: "requestID", value: request.id),
            URLQueryItem(name: "requestedAt", value: String(request.requestedAt)),
            URLQueryItem(name: "command", value: request.command.rawValue),
            URLQueryItem(name: "manualReturn", value: "1")
        ]
        if let sourceHost = request.sourceHost {
            components.queryItems?.append(contentsOf: [
                URLQueryItem(
                    name: "sourceHostBundleIdentifier",
                    value: sourceHost.bundleIdentifier
                ),
                URLQueryItem(
                    name: "sourceHostCapturedAt",
                    value: String(sourceHost.capturedAt)
                ),
                URLQueryItem(
                    name: "sourceHostGeneration",
                    value: sourceHost.generation
                )
            ])
        }
        return components.url
    }

    private func insertRecognitionResultIfNeeded(isRecording: Bool, isTranscribing: Bool, now: TimeInterval) {
        guard !isRecording,
              !isTranscribing,
              SharedCommandStore.isKeyboardAutoInsertPending(),
              let result = SharedCommandStore.latestRecognitionResult(),
              result.id != lastHandledRecognitionResultID,
              result.id != SharedCommandStore.latestInsertedRecognitionResultID() else {
            return
        }

        let requestedAt = SharedCommandStore.latestKeyboardAutoInsertRequestedAt()
        guard now - requestedAt < 900 else {
            SharedCommandStore.cancelKeyboardAutoInsert()
            return
        }

        let isFromCurrentKeyboardRequest = requestedAt > 0
            && result.createdAt >= requestedAt
            && result.createdAt - requestedAt < 900
        let isRecentResult = now - result.createdAt < 30

        guard isFromCurrentKeyboardRequest, isRecentResult else {
            return
        }

        textDocumentProxy.insertText(result.text)
        lastHandledRecognitionResultID = result.id
        SharedCommandStore.markRecognitionResultInserted(result.id)
        statusLabel.text = "已插入"
        statusLabel.textColor = .systemGreen
        insertionMessageUntil = now + 1.5
    }

    private func openContainingApp(
        _ url: URL?,
        reason: String,
        request: SharedRecordingToggleRequest? = nil
    ) {
        guard let url else {
            SharedCommandStore.recordKeyboardDiagnostic(
                "containing_app_url_invalid",
                detail: reason
            )
            statusLabel.text = "无法生成 AgenBoard 启动链接"
            return
        }

        SharedCommandStore.recordKeyboardDiagnostic(
            "containing_app_open_requested",
            detail: "reason=\(reason) url=\(url.absoluteString)"
        )
        RecordingLaunchMetrics.mark(
            "keyboard_system_open_requested",
            request: request,
            detail: reason
        )

        if openURLThroughHostingScene(url) {
            SharedCommandStore.recordKeyboardDiagnostic(
                "containing_app_open_via_scene",
                detail: reason
            )
            statusLabel.text = "正在请求系统打开 AgenBoard..."
            scheduleAppOpenVerification()
            return
        }

        guard let extensionContext else {
            showLaunchFailure("无法请求系统打开 AgenBoard")
            return
        }

        extensionContext.open(url) { [weak self] success in
            DispatchQueue.main.async {
                SharedCommandStore.recordKeyboardDiagnostic(
                    success
                        ? "containing_app_open_via_extension_succeeded"
                        : "containing_app_open_via_extension_failed",
                    detail: reason
                )
                if success {
                    self?.statusLabel.text = "正在打开 AgenBoard..."
                    self?.scheduleAppOpenVerification()
                } else {
                    self?.showLaunchFailure("系统未允许键盘打开 AgenBoard")
                }
            }
        }
    }

    private func openURLThroughHostingScene(_ url: URL) -> Bool {
        if let scene = view.window?.windowScene {
            requestOpen(url, through: scene)
            return true
        }

        var responder: UIResponder? = self

        while let currentResponder = responder {
            if let scene = currentResponder as? UIScene {
                requestOpen(url, through: scene)
                return true
            }

            responder = currentResponder.next
        }

        let legacySelector = NSSelectorFromString("openURL:")
        responder = self

        while let currentResponder = responder {
            if currentResponder.responds(to: legacySelector) {
                currentResponder.perform(legacySelector, with: url)
                return true
            }

            responder = currentResponder.next
        }

        return false
    }

    private func requestOpen(_ url: URL, through scene: UIScene) {
        scene.open(url, options: nil) { [weak self] success in
            if success {
                self?.statusLabel.text = "正在打开 AgenBoard..."
            } else {
                self?.showLaunchFailure("系统未允许键盘打开 AgenBoard")
            }
        }
    }

    private func scheduleAppOpenVerification() {
        appOpenVerificationTask?.cancel()
        appOpenVerificationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 2_500_000_000)
            } catch {
                return
            }

            guard let self else {
                return
            }

            let snapshot = SharedCommandStore.latestRecordingSnapshot()
            let isAppResponsive = Date().timeIntervalSince1970 - snapshot.updatedAt < 1.5

            if !isAppResponsive {
                self.showLaunchFailure("AgenBoard 未能打开，请再点一次")
            }
        }
    }

    private func scheduleRecordingCommandFallback(
        for request: SharedRecordingToggleRequest
    ) {
        recordingCommandFallbackTask?.cancel()
        recordingCommandFallbackTask = Task { @MainActor [weak self] in
            let startedAt = ProcessInfo.processInfo.systemUptime
            var wasAccepted = false
            var fallbackReason = "no_acknowledgement"

            while !Task.isCancelled {
                guard let self else {
                    return
                }

                guard SharedCommandStore.latestRecordingToggleRequest()?.id
                        == request.id else {
                    self.recordingCommandFallbackTask = nil
                    return
                }

                if let response = SharedCommandStore.latestRecordingRequestResponse(),
                   response.requestID == request.id,
                   response.command == request.command {
                    switch response.phase {
                    case .accepted:
                        wasAccepted = true
                    case .recording where request.command == .start,
                         .stopped where request.command == .stop:
                        RecordingLaunchMetrics.mark(
                            "keyboard_recording_command_succeeded",
                            request: request,
                            detail: response.phase.rawValue
                        )
                        self.recordingCommandFallbackTask = nil
                        return
                    case .failed:
                        fallbackReason = response.message.isEmpty
                            ? "command_failed"
                            : response.message
                        self.recordingCommandFallbackTask = nil
                        self.foregroundContainingApp(
                            for: request,
                            reason: fallbackReason
                        )
                        return
                    default:
                        break
                    }
                }

                let snapshot = SharedCommandStore.latestRecordingSnapshot()
                let isFresh = Date().timeIntervalSince1970 - snapshot.updatedAt < 1.5
                let reachedRequestedState = isFresh && (
                    (request.command == .start && snapshot.isRecording)
                        || (request.command == .stop && !snapshot.isRecording)
                )
                if reachedRequestedState {
                    self.recordingCommandFallbackTask = nil
                    return
                }

                let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
                let deadline = wasAccepted ? 1.0 : 0.32
                if elapsed >= deadline {
                    fallbackReason = wasAccepted
                        ? "accepted_without_completion"
                        : "no_acknowledgement"
                    break
                }

                do {
                    try await Task.sleep(nanoseconds: 40_000_000)
                } catch {
                    return
                }
            }

            guard let self else {
                return
            }
            self.recordingCommandFallbackTask = nil
            self.foregroundContainingApp(for: request, reason: fallbackReason)
        }
    }

    private func foregroundContainingApp(
        for request: SharedRecordingToggleRequest,
        reason: String
    ) {
        RecordingLaunchMetrics.mark(
            "keyboard_recording_command_fallback",
            request: request,
            detail: reason
        )
        appLaunchRequestedAt = Date().timeIntervalSince1970
        statusLabel.text = request.command == .start
            ? "后台录音不可用，正在打开 AgenBoard..."
            : "停止请求未响应，正在打开 AgenBoard..."
        openContainingApp(
            recordingURL(for: request),
            reason: "recording_command_\(reason)",
            request: request
        )
    }

    private func showLaunchFailure(_ message: String) {
        appOpenVerificationTask?.cancel()
        appOpenVerificationTask = nil
        appLaunchRequestedAt = nil
        launchFailureMessage = message
        launchFailureMessageUntil = Date().timeIntervalSince1970 + 4
        statusLabel.text = message
        statusLabel.textColor = .systemRed
        refreshRecordingSnapshot()
    }

    @objc private func insertSpace() {
        if commitBestPinyinCandidateIfNeeded() {
            refreshPinyinCandidateRow()
            return
        }
        insert(" ")
    }

    @objc private func handleSpaceCursorTracking(
        _ gesture: UILongPressGestureRecognizer
    ) {
        switch gesture.state {
        case .began:
            guard let button = gesture.view as? UIButton else {
                return
            }
            beginCursorTracking(
                on: button,
                at: gesture.location(in: view)
            )
        case .changed:
            updateCursorTracking(at: gesture.location(in: view))
        case .ended:
            updateCursorTracking(at: gesture.location(in: view))
            endCursorTracking()
        case .cancelled, .failed:
            endCursorTracking()
        default:
            break
        }
    }

    private func beginCursorTracking(on button: UIButton, at location: CGPoint) {
        guard !isCursorTracking else {
            return
        }

        if finalizeRawPinyinCompositionIfNeeded() {
            refreshPinyinCandidateRow()
        }

        isCursorTracking = true
        cursorTrackingButton = button
        cursorTrackingStartLocation = location
        cursorTrackingDesiredOffset = 0
        cursorTrackingAppliedOffset = 0
        cursorTrackingCharactersPerLine = estimatedCharactersPerVisualLine()

        if hapticsEnabled {
            cursorTrackingFeedbackGenerator.prepare()
            cursorTrackingFeedbackGenerator.impactOccurred(intensity: 0.7)
        }

        cursorTrackingDefaultConfiguration = button.configuration
        var configuration = button.configuration
        configuration?.title = nil
        configuration?.image = UIImage(
            systemName: "arrow.up.and.down.and.arrow.left.and.right"
        )
        configuration?.preferredSymbolConfigurationForImage = .init(
            pointSize: 20,
            weight: .medium
        )
        configuration?.baseBackgroundColor = .systemGray4
        button.configuration = configuration

        statusLabel.text = "拖动空格键移动光标"
        statusLabel.textColor = .systemBlue

        let displayLink = CADisplayLink(
            target: self,
            selector: #selector(applyPendingCursorTrackingMovement)
        )
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: 30,
            maximum: 60,
            preferred: 60
        )
        displayLink.add(to: .main, forMode: .common)
        cursorTrackingDisplayLink = displayLink
    }

    private func updateCursorTracking(at location: CGPoint) {
        guard isCursorTracking else {
            return
        }

        let translation = CGPoint(
            x: location.x - cursorTrackingStartLocation.x,
            y: location.y - cursorTrackingStartLocation.y
        )
        let horizontalOffset = Int(
            (translation.x / 8).rounded(.towardZero)
        )
        let verticalLineOffset = Int(
            (translation.y / 22).rounded(.towardZero)
        )
        cursorTrackingDesiredOffset = horizontalOffset
            + verticalLineOffset * cursorTrackingCharactersPerLine
    }

    @objc private func applyPendingCursorTrackingMovement() {
        guard isCursorTracking else {
            return
        }

        let requestedOffset = cursorTrackingDesiredOffset
            - cursorTrackingAppliedOffset
        guard requestedOffset != 0 else {
            return
        }

        var applicableOffset = requestedOffset
        if requestedOffset < 0,
           let context = textDocumentProxy.documentContextBeforeInput {
            guard !context.isEmpty else {
                cursorTrackingAppliedOffset = cursorTrackingDesiredOffset
                return
            }
            applicableOffset = max(requestedOffset, -context.count)
        } else if requestedOffset > 0,
                  let context = textDocumentProxy.documentContextAfterInput {
            guard !context.isEmpty else {
                cursorTrackingAppliedOffset = cursorTrackingDesiredOffset
                return
            }
            applicableOffset = min(requestedOffset, context.count)
        }

        textDocumentProxy.adjustTextPosition(
            byCharacterOffset: applicableOffset
        )
        if applicableOffset == requestedOffset {
            cursorTrackingAppliedOffset += applicableOffset
        } else {
            cursorTrackingAppliedOffset = cursorTrackingDesiredOffset
        }
    }

    private func endCursorTracking(refreshSnapshot: Bool = true) {
        guard isCursorTracking else {
            return
        }

        applyPendingCursorTrackingMovement()
        isCursorTracking = false
        cursorTrackingDisplayLink?.invalidate()
        cursorTrackingDisplayLink = nil
        cursorTrackingDesiredOffset = 0
        cursorTrackingAppliedOffset = 0

        if let cursorTrackingButton, let cursorTrackingDefaultConfiguration {
            cursorTrackingButton.configuration = cursorTrackingDefaultConfiguration
        }
        cursorTrackingButton = nil
        cursorTrackingDefaultConfiguration = nil

        if refreshSnapshot {
            refreshRecordingSnapshot()
        }
    }

    private func estimatedCharactersPerVisualLine() -> Int {
        let context = (textDocumentProxy.documentContextBeforeInput ?? "")
            + (textDocumentProxy.documentContextAfterInput ?? "")
        let sample = context.prefix(160).filter { !$0.isNewline }
        let averageCharacterWidth: CGFloat

        if sample.isEmpty {
            averageCharacterWidth = 0.78
        } else {
            let totalWidth = sample.reduce(CGFloat.zero) { partialResult, character in
                partialResult + relativeCharacterWidth(character)
            }
            averageCharacterWidth = totalWidth / CGFloat(sample.count)
        }

        let availableWidth = max(240, view.bounds.width - 32)
        let fullWidthCharacterCount = availableWidth / 16.5
        let estimate = Int(
            (fullWidthCharacterCount / max(0.45, averageCharacterWidth)).rounded()
        )
        return min(56, max(14, estimate))
    }

    private func relativeCharacterWidth(_ character: Character) -> CGFloat {
        guard character.unicodeScalars.allSatisfy(\.isASCII) else {
            return 1
        }

        if character.isWhitespace {
            return 0.42
        }

        if "ilI1.,'`:;|!".contains(character) {
            return 0.34
        }

        if "mwMW@#%&".contains(character) {
            return 0.92
        }

        return 0.58
    }

    @objc private func insertReturn() {
        // Return confirms the visible Latin composition instead of forcing the
        // first Chinese candidate, matching the native Simplified Pinyin flow.
        if finalizeRawPinyinCompositionIfNeeded() {
            refreshPinyinCandidateRow()
            return
        }
        insert("\n")
    }

    @objc private func insertAtSign() {
        if commitBestPinyinCandidateIfNeeded() {
            refreshPinyinCandidateRow()
        }
        insert("@")
    }

    @objc private func startDeleting() {
        stopDeleting()
        deleteBackward()

        let timer = Timer(
            timeInterval: 0.42,
            target: self,
            selector: #selector(beginRepeatedDeletion),
            userInfo: nil,
            repeats: false
        )
        deleteRepeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func beginRepeatedDeletion() {
        deleteRepeatTimer?.invalidate()
        let timer = Timer(
            timeInterval: 0.075,
            target: self,
            selector: #selector(deleteBackward),
            userInfo: nil,
            repeats: true
        )
        deleteRepeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func stopDeleting() {
        deleteRepeatTimer?.invalidate()
        deleteRepeatTimer = nil
    }

    @objc private func deleteBackward() {
        if keyboardLanguage == .pinyin,
           keyboardPage == .letters,
           !pinyinComposition.isEmpty {
            pinyinComposition.removeLast()
            if pinyinComposition.isEmpty {
                textDocumentProxy.setMarkedText(
                    "",
                    selectedRange: .init(location: 0, length: 0)
                )
                textDocumentProxy.unmarkText()
            } else {
                updateMarkedPinyinComposition()
            }
            // Only refresh the candidate strip. Rebuilding the pressed delete
            // button here would prevent it from receiving the matching touch-up.
            refreshPinyinCandidateRow()
            return
        }
        textDocumentProxy.deleteBackward()
    }

}

private final class PinyinCandidateButton: UIButton {
    var candidateValue = ""
}

private final class PinyinCandidateCollectionCell: UICollectionViewCell {
    private let titleLabel = UILabel()
    private let imageView = UIImageView()
    private var baseBackgroundColor: UIColor = .clear

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureLayout()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayout()
    }

    override var isHighlighted: Bool {
        didSet {
            contentView.backgroundColor = isHighlighted
                ? .systemGray3
                : baseBackgroundColor
        }
    }

    func configure(title: String, isPrimary: Bool) {
        titleLabel.text = title
        titleLabel.isHidden = false
        imageView.isHidden = true
        baseBackgroundColor = isPrimary ? .systemGray4 : .clear
        contentView.backgroundColor = baseBackgroundColor
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "输入候选词 \(title)"
    }

    func configureAsCollapseButton() {
        titleLabel.isHidden = true
        imageView.isHidden = false
        imageView.image = UIImage(systemName: "chevron.up")
        baseBackgroundColor = .clear
        contentView.backgroundColor = baseBackgroundColor
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "收起候选词"
    }

    func configureAsPlaceholder() {
        titleLabel.isHidden = true
        imageView.isHidden = true
        baseBackgroundColor = .clear
        contentView.backgroundColor = baseBackgroundColor
        isAccessibilityElement = false
        accessibilityLabel = nil
    }

    private func configureLayout() {
        contentView.layer.cornerRadius = 8
        contentView.layer.cornerCurve = .continuous

        titleLabel.font = .systemFont(ofSize: 17, weight: .regular)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.72
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)

        imageView.tintColor = .secondaryLabel
        imageView.preferredSymbolConfiguration = .init(
            pointSize: 14,
            weight: .semibold
        )
        imageView.contentMode = .center
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 2),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }
}

private final class KeyboardTypingSurfaceView: UIView {
    private final class TouchState {
        weak var activeButton: UIButton?
        var longPressTimer: Timer?
        var isCursorTracking = false
        var lastLocation = CGPoint.zero
    }

    private let rowsStack = UIStackView()
    private var buttonRows: [[UIButton]] = []
    private var touchStates: [ObjectIdentifier: TouchState] = [:]
    private var highlightCounts: [ObjectIdentifier: Int] = [:]
    private weak var cursorTrackingState: TouchState?

    weak var cursorTrackingButton: UIButton?
    var onCursorTrackingBegan: ((UIButton, CGPoint) -> Void)?
    var onCursorTrackingChanged: ((CGPoint) -> Void)?
    var onCursorTrackingEnded: ((CGPoint) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureLayout()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayout()
    }

    func addRow(_ row: UIView, buttons: [UIButton]) {
        rowsStack.addArrangedSubview(row)
        buttonRows.append(buttons)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if UIAccessibility.isVoiceOverRunning {
            return super.hitTest(point, with: event)
        }
        guard isUserInteractionEnabled,
              !isHidden,
              alpha >= 0.01,
              self.point(inside: point, with: event) else {
            return nil
        }
        return self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard cursorTrackingState == nil else {
            return
        }

        for touch in touches {
            let location = touch.location(in: self)
            guard let button = button(at: location) else {
                continue
            }
            let state = TouchState()
            state.lastLocation = location
            touchStates[ObjectIdentifier(touch)] = state
            activate(button, for: state)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)

        for touch in touches {
            guard let state = touchStates[ObjectIdentifier(touch)] else {
                continue
            }
            let location = touch.location(in: self)
            state.lastLocation = location

            if state.isCursorTracking {
                onCursorTrackingChanged?(location)
            } else if let button = button(at: location) {
                activate(button, for: state)
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        touches.forEach { finishTouch($0, cancelled: false) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        touches.forEach { finishTouch($0, cancelled: true) }
    }

    private func configureLayout() {
        isMultipleTouchEnabled = true
        isAccessibilityElement = false

        rowsStack.axis = .vertical
        rowsStack.alignment = .fill
        rowsStack.distribution = .fillEqually
        rowsStack.spacing = 7
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowsStack)

        NSLayoutConstraint.activate([
            rowsStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            rowsStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])
    }

    private func activate(_ button: UIButton, for state: TouchState) {
        guard state.activeButton !== button else {
            return
        }

        state.longPressTimer?.invalidate()
        state.longPressTimer = nil

        if let previousButton = state.activeButton {
            setHighlighted(false, for: previousButton)
            previousButton.sendActions(for: .touchDragExit)
        }

        state.activeButton = button
        setHighlighted(true, for: button)
        button.sendActions(for: .touchDown)

        if button === cursorTrackingButton {
            scheduleCursorTracking(for: state, button: button)
        }
    }

    private func scheduleCursorTracking(for state: TouchState, button: UIButton) {
        let timer = Timer(
            timeInterval: 0.3,
            target: self,
            selector: #selector(beginCursorTrackingFromTimer(_:)),
            userInfo: state,
            repeats: false
        )
        state.longPressTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func beginCursorTrackingFromTimer(_ timer: Timer) {
        guard let state = timer.userInfo as? TouchState,
              let button = state.activeButton,
              button === cursorTrackingButton,
              cursorTrackingState == nil,
              touchStates.values.contains(where: { $0 === state }) else {
            return
        }

        state.longPressTimer = nil
        state.isCursorTracking = true
        cursorTrackingState = state
        onCursorTrackingBegan?(button, state.lastLocation)
    }

    private func finishTouch(_ touch: UITouch, cancelled: Bool) {
        let key = ObjectIdentifier(touch)
        guard let state = touchStates.removeValue(forKey: key) else {
            return
        }

        state.longPressTimer?.invalidate()
        state.longPressTimer = nil
        let button = state.activeButton

        if state.isCursorTracking {
            onCursorTrackingEnded?(state.lastLocation)
            if cursorTrackingState === state {
                cursorTrackingState = nil
            }
            button?.sendActions(for: .touchCancel)
        } else if cancelled {
            button?.sendActions(for: .touchCancel)
        } else {
            button?.sendActions(for: .touchUpInside)
        }

        if let button {
            setHighlighted(false, for: button)
        }
        state.activeButton = nil
    }

    private func setHighlighted(_ highlighted: Bool, for button: UIButton) {
        let key = ObjectIdentifier(button)
        let currentCount = highlightCounts[key, default: 0]
        let nextCount = highlighted ? currentCount + 1 : max(0, currentCount - 1)

        if nextCount == 0 {
            highlightCounts.removeValue(forKey: key)
            button.isHighlighted = false
        } else {
            highlightCounts[key] = nextCount
            button.isHighlighted = true
        }
    }

    private func button(at location: CGPoint) -> UIButton? {
        layoutIfNeeded()
        let rows = buttonRows.filter { !$0.isEmpty }
        guard !rows.isEmpty else {
            return nil
        }

        let rowFrames = rows.map { buttons in
            buttons.reduce(CGRect.null) { partial, button in
                partial.union(button.convert(button.bounds, to: self))
            }
        }

        var selectedRowIndex = rows.count - 1
        for index in rows.indices.dropLast() {
            let boundary = (rowFrames[index].maxY + rowFrames[index + 1].minY) / 2
            if location.y < boundary {
                selectedRowIndex = index
                break
            }
        }

        let buttons = rows[selectedRowIndex]
        let frames = buttons.map { $0.convert($0.bounds, to: self) }
        for index in buttons.indices.dropLast() {
            let boundary = (frames[index].maxX + frames[index + 1].minX) / 2
            if location.x < boundary {
                return buttons[index]
            }
        }
        return buttons.last
    }
}

private final class KeyboardAudioLevelView: UIView {
    private let barWeights: [CGFloat] = [0.46, 0.68, 0.86, 1, 0.86, 0.68, 0.46]
    private var heightConstraints: [NSLayoutConstraint] = []
    private var displayedLevel: CGFloat = 0
    private var phase: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureBars()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureBars()
    }

    func update(level: Double, isActive: Bool) {
        let target = isActive ? CGFloat(max(0, min(1, level))) : 0
        displayedLevel = displayedLevel * 0.28 + target * 0.72
        phase += 0.72

        for (index, constraint) in heightConstraints.enumerated() {
            let oscillation = 0.62 + 0.38 * abs(sin(phase + CGFloat(index) * 0.83))
            let energy = min(1, displayedLevel * 1.65)
            constraint.constant = 5 + 34 * energy * barWeights[index] * oscillation
        }

        UIView.animate(
            withDuration: 0.075,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
        ) {
            self.layoutIfNeeded()
        }
    }

    private func configureBars() {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.distribution = .equalCentering
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for _ in barWeights {
            let bar = UIView()
            bar.backgroundColor = .systemBackground
            bar.layer.cornerRadius = 2.5
            bar.layer.cornerCurve = .continuous
            bar.translatesAutoresizingMaskIntoConstraints = false
            let heightConstraint = bar.heightAnchor.constraint(equalToConstant: 5)
            NSLayoutConstraint.activate([
                bar.widthAnchor.constraint(equalToConstant: 5),
                heightConstraint
            ])
            heightConstraints.append(heightConstraint)
            stack.addArrangedSubview(bar)
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}
