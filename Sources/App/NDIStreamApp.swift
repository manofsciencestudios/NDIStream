import AppKit
import AVFoundation
import Combine

enum DebugLog {
    private static let lock = NSLock()

    static var url: URL {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop", isDirectory: true)
        return desktop.appendingPathComponent("NDIStream-debug.log")
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        let header = "NDIStream debug log started \(timestamp())\npath=\(url.path)\n\n"
        try? header.write(to: url, atomically: true, encoding: .utf8)
    }

    static func write(_ message: String,
                      file: StaticString = #fileID,
                      line: UInt = #line) {
        let lineText = "\(timestamp()) [\(file):\(line)] \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "NDIStream debug log started \(timestamp())\npath=\(url.path)\n\n".write(to: url, atomically: true, encoding: .utf8)
        }
        guard let data = lineText.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

@MainActor
enum ActivityKeeper {
    private static var reasons: Set<String> = []
    private static var token: NSObjectProtocol?
    private static var keepAliveWindow: NSWindow?

    static func begin(_ reason: String) {
        reasons.insert(reason)
        showKeepAliveWindow()
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(
            options: [
                .userInitiated,
                .latencyCritical,
                .idleSystemSleepDisabled,
                .suddenTerminationDisabled,
                .automaticTerminationDisabled
            ],
            reason: "NDIStream active video: \(reason)"
        )
        DebugLog.write("activity begin reasons=\(Array(reasons).sorted())")
    }

    static func end(_ reason: String) {
        reasons.remove(reason)
        guard reasons.isEmpty, let active = token else { return }
        ProcessInfo.processInfo.endActivity(active)
        token = nil
        hideKeepAliveWindow()
        DebugLog.write("activity end")
    }

    private static func showKeepAliveWindow() {
        guard keepAliveWindow == nil else { return }

        let size = NSSize(width: 2, height: 2)
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(
            x: visibleFrame.maxX - size.width - 1,
            y: visibleFrame.minY + 1,
            width: size.width,
            height: size.height
        )

        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.02).cgColor

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.alphaValue = 0.02
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        window.orderFrontRegardless()
        keepAliveWindow = window
        DebugLog.write("keepalive window shown frame=\(NSStringFromRect(frame))")
    }

    private static func hideKeepAliveWindow() {
        guard let window = keepAliveWindow else { return }
        window.orderOut(nil)
        keepAliveWindow = nil
        DebugLog.write("keepalive window hidden")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let senderController = BroadcastController()
    private let receiverModel = ReceiverModel()
    private var cancellables: Set<AnyCancellable> = []
    private var statusItem: NSStatusItem!
    private var statusBroadcastItem: NSMenuItem!
    private var statusReceiverItem: NSMenuItem!
    private var statusSenderWindowItem: NSMenuItem!
    private var statusReceiverWindowItem: NSMenuItem!
    private var statusHideWindowsItem: NSMenuItem!
    private var statusLineItem: NSMenuItem!

    private var senderWindow: NSWindow!
    private var receiverWindow: NSWindow!

    private var cameraLabel = NSTextField(labelWithString: "")
    private var sourceNameField = NSTextField(string: "")
    private var qualityControl = NSSegmentedControl()
    private var fpsControl = NSSegmentedControl()
    private var pixelFormatControl = NSSegmentedControl()
    private var pacingCheckbox = NSButton()
    private var lowestLatencyCheckbox = NSButton()
    private var lowestLatencyPendingLabel = NSTextField(labelWithString: "Pending relaunch")
    private var advancedContainer = NSStackView()
    private var advancedDisclosureButton = NSButton()
    private var senderRecordButton = NSButton()
    private var senderTimerLabel = NSTextField(labelWithString: "00:00")
    private var senderErrorLabel = NSTextField(labelWithString: "")
    private var senderSlateField = NSTextField(string: "")
    private var senderAutoRecordCheckbox = NSButton()
    private var senderLockButton = NSButton()
    private var senderCameraPrevButton = NSButton()
    private var senderCameraNextButton = NSButton()
    private var senderAudioPrevButton = NSButton()
    private var senderAudioNextButton = NSButton()
    private var senderAudioLabel = NSTextField(labelWithString: "")
    private var senderAudioCheckbox = NSButton()
    private var senderFolderButton = NSButton()
    private var senderLogButton = NSButton()
    private var logPathLabel = NSTextField(labelWithString: "")
    private var broadcastButton = NSButton()
    private var senderStatusDot = NSView()
    private var senderStatusLabel = NSTextField(labelWithString: "Idle")

    private var receiverSourceLabel = NSTextField(labelWithString: "")
    private var receiverConnectButton = NSButton()
    private var receiverStatusLabel = NSTextField(labelWithString: "")
    private var receiverRecordButton = NSButton()
    private var receiverTimerLabel = NSTextField(labelWithString: "00:00")
    private var receiverErrorLabel = NSTextField(labelWithString: "")
    private var receiverSlateField = NSTextField(string: "")
    private var receiverAutoRecordCheckbox = NSButton()
    private var receiverAudioCheckbox = NSButton()
    private var receiverLockButton = NSButton()
    private var receiverSourcePrevButton = NSButton()
    private var receiverSourceNextButton = NSButton()
    private var receiverFolderButton = NSButton()
    private var receiverTallyDot = NSView()
    private var receiverTopBar: NSStackView!
    private var receiverBottomBar: NSStackView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugLog.write("applicationDidFinishLaunching")
        DebugLog.write("logPath=\(DebugLog.url.path)")
        NSApp.setActivationPolicy(.regular)
        installMenu()
        installStatusItem()
        buildSenderWindow()
        buildReceiverWindow()
        bindUpdates()
        senderController.refreshCameras()
        updateSenderUI()
        updateReceiverUI()
        senderWindow.makeKeyAndOrderFront(nil)
        receiverWindow.orderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DebugLog.write("windows ordered front")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func installMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit NDIStream", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Sender", action: #selector(showSenderWindow), keyEquivalent: "1"))
        windowMenu.addItem(NSMenuItem(title: "Receiver", action: #selector(showReceiverWindow), keyEquivalent: "2"))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.mainMenu = mainMenu
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "NDI"
        statusItem.button?.toolTip = "NDIStream"

        let menu = NSMenu()
        statusLineItem = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
        statusLineItem.isEnabled = false
        menu.addItem(statusLineItem)
        menu.addItem(.separator())

        statusBroadcastItem = NSMenuItem(title: "Start Broadcasting", action: #selector(toggleBroadcastFromStatusItem), keyEquivalent: "")
        statusBroadcastItem.target = self
        menu.addItem(statusBroadcastItem)

        statusReceiverItem = NSMenuItem(title: "Connect Receiver", action: #selector(toggleReceiverFromStatusItem), keyEquivalent: "")
        statusReceiverItem.target = self
        menu.addItem(statusReceiverItem)

        menu.addItem(.separator())
        statusSenderWindowItem = NSMenuItem(title: "Show Sender Window", action: #selector(showSenderWindow), keyEquivalent: "")
        statusSenderWindowItem.target = self
        menu.addItem(statusSenderWindowItem)

        statusReceiverWindowItem = NSMenuItem(title: "Show Receiver Window", action: #selector(showReceiverWindow), keyEquivalent: "")
        statusReceiverWindowItem.target = self
        menu.addItem(statusReceiverWindowItem)

        statusHideWindowsItem = NSMenuItem(title: "Hide Windows", action: #selector(hideWindows), keyEquivalent: "")
        statusHideWindowsItem.target = self
        menu.addItem(statusHideWindowsItem)

        menu.addItem(.separator())
        let logItem = NSMenuItem(title: "Open Debug Log", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit NDIStream", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        menu.delegate = self
        statusItem.menu = menu
        DebugLog.write("status item installed")
    }

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        Task { @MainActor in self.updateStatusMenu() }
    }

    private func buildSenderWindow() {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)

        content.addArrangedSubview(sectionLabel("Camera"))
        let cameraRow = row()
        senderCameraPrevButton = button("‹", action: #selector(previousCamera), width: 32)
        senderCameraNextButton = button("›", action: #selector(nextCamera), width: 32)
        cameraRow.addArrangedSubview(senderCameraPrevButton)
        cameraLabel.lineBreakMode = .byTruncatingMiddle
        cameraLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cameraRow.addArrangedSubview(cameraLabel)
        cameraRow.addArrangedSubview(senderCameraNextButton)
        content.addArrangedSubview(cameraRow)

        content.addArrangedSubview(sectionLabel("Microphone"))
        let audioRow = row()
        senderAudioPrevButton = button("‹", action: #selector(previousAudioDevice), width: 32)
        senderAudioNextButton = button("›", action: #selector(nextAudioDevice), width: 32)
        audioRow.addArrangedSubview(senderAudioPrevButton)
        senderAudioLabel.lineBreakMode = .byTruncatingMiddle
        senderAudioLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        audioRow.addArrangedSubview(senderAudioLabel)
        audioRow.addArrangedSubview(senderAudioNextButton)
        content.addArrangedSubview(audioRow)

        senderAudioCheckbox = NSButton(checkboxWithTitle: "Send microphone audio over NDI", target: self, action: #selector(senderAudioChanged))
        content.addArrangedSubview(senderAudioCheckbox)

        content.addArrangedSubview(sectionLabel("NDI source name"))
        sourceNameField.target = self
        sourceNameField.action = #selector(sourceNameEdited)
        sourceNameField.isContinuous = false
        sourceNameField.widthAnchor.constraint(equalToConstant: 400).isActive = true
        content.addArrangedSubview(sourceNameField)

        content.addArrangedSubview(sectionLabel("Slate (used in recording filename)"))
        senderSlateField.target = self
        senderSlateField.action = #selector(senderSlateEdited)
        senderSlateField.isContinuous = false
        senderSlateField.placeholderString = "e.g. S14T3"
        senderSlateField.widthAnchor.constraint(equalToConstant: 400).isActive = true
        content.addArrangedSubview(senderSlateField)

        let preview = PreviewNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 225))
        preview.attach(session: senderController.cameraManager.session)
        preview.widthAnchor.constraint(equalToConstant: 400).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 225).isActive = true
        content.addArrangedSubview(preview)

        advancedContainer.orientation = .vertical
        advancedContainer.alignment = .leading
        advancedContainer.spacing = 8
        advancedContainer.isHidden = true

        qualityControl = NSSegmentedControl(labels: QualityPreset.allCases.map(\.label), trackingMode: .selectOne, target: self, action: #selector(qualityChanged))
        advancedContainer.addArrangedSubview(labeledRow("Quality", qualityControl))

        fpsControl = NSSegmentedControl(labels: ["30", "60"], trackingMode: .selectOne, target: self, action: #selector(fpsChanged))
        advancedContainer.addArrangedSubview(labeledRow("Frame rate", fpsControl))

        pixelFormatControl = NSSegmentedControl(labels: CapturePixelFormat.allCases.map(\.label), trackingMode: .selectOne, target: self, action: #selector(pixelFormatChanged))
        advancedContainer.addArrangedSubview(labeledRow("Format", pixelFormatControl))

        pacingCheckbox = NSButton(checkboxWithTitle: "Smooth pacing (+1 frame latency)", target: self, action: #selector(pacingChanged))
        advancedContainer.addArrangedSubview(pacingCheckbox)

        lowestLatencyCheckbox = NSButton(checkboxWithTitle: "Lowest latency (unicast UDP, no RUDP; relaunch to apply)", target: self, action: #selector(lowestLatencyChanged))
        advancedContainer.addArrangedSubview(lowestLatencyCheckbox)
        lowestLatencyPendingLabel.textColor = .systemOrange
        lowestLatencyPendingLabel.font = .systemFont(ofSize: 11)
        lowestLatencyPendingLabel.isHidden = true
        advancedContainer.addArrangedSubview(lowestLatencyPendingLabel)

        advancedDisclosureButton.title = "▸  Advanced (quality, frame rate, latency)"
        advancedDisclosureButton.bezelStyle = .inline
        advancedDisclosureButton.setButtonType(.toggle)
        advancedDisclosureButton.target = self
        advancedDisclosureButton.action = #selector(toggleAdvanced)
        advancedDisclosureButton.contentTintColor = .secondaryLabelColor
        advancedDisclosureButton.font = .systemFont(ofSize: 11)
        content.addArrangedSubview(advancedDisclosureButton)
        content.addArrangedSubview(advancedContainer)

        senderAutoRecordCheckbox = NSButton(checkboxWithTitle: "Auto-record when broadcasting starts", target: self, action: #selector(senderAutoRecordChanged))
        content.addArrangedSubview(senderAutoRecordCheckbox)

        let recordRow = row()
        senderRecordButton = NSButton(title: "REC", target: self, action: #selector(toggleSenderRecording))
        senderTimerLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        senderErrorLabel.textColor = .systemRed
        senderErrorLabel.lineBreakMode = .byTruncatingMiddle
        senderFolderButton = button("Folder", action: #selector(revealRecordings), width: 70)
        senderLogButton = button("Log", action: #selector(openLog), width: 50)
        senderLockButton = button("🔓", action: #selector(toggleSenderLock), width: 44)
        recordRow.addArrangedSubview(senderRecordButton)
        recordRow.addArrangedSubview(senderTimerLabel)
        recordRow.addArrangedSubview(senderErrorLabel)
        recordRow.addArrangedSubview(senderFolderButton)
        recordRow.addArrangedSubview(senderLogButton)
        recordRow.addArrangedSubview(senderLockButton)
        content.addArrangedSubview(recordRow)

        broadcastButton = NSButton(title: "Start Broadcasting", target: self, action: #selector(toggleBroadcast))
        broadcastButton.bezelStyle = .rounded
        broadcastButton.widthAnchor.constraint(equalToConstant: 400).isActive = true
        content.addArrangedSubview(broadcastButton)

        let statusRow = row()
        senderStatusDot.wantsLayer = true
        senderStatusDot.layer?.cornerRadius = 5
        senderStatusDot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        senderStatusDot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        senderStatusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        senderStatusLabel.lineBreakMode = .byTruncatingTail
        statusRow.addArrangedSubview(senderStatusDot)
        statusRow.addArrangedSubview(senderStatusLabel)
        content.addArrangedSubview(statusRow)

        senderWindow = makeWindow(title: "NDIStream - Sender", content: content, size: NSSize(width: 440, height: 640))
        senderWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        resizeSenderWindowToFitContent(animate: false)
    }

    private func buildReceiverWindow() {
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 0

        let topBar = row()
        topBar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 4, right: 10)
        receiverTallyDot.wantsLayer = true
        receiverTallyDot.layer?.cornerRadius = 6
        receiverTallyDot.widthAnchor.constraint(equalToConstant: 12).isActive = true
        receiverTallyDot.heightAnchor.constraint(equalToConstant: 12).isActive = true
        topBar.addArrangedSubview(receiverTallyDot)
        receiverSourcePrevButton = button("‹", action: #selector(previousSource), width: 28)
        receiverSourceNextButton = button("›", action: #selector(nextSource), width: 28)
        topBar.addArrangedSubview(receiverSourcePrevButton)
        receiverSourceLabel.lineBreakMode = .byTruncatingMiddle
        receiverSourceLabel.widthAnchor.constraint(equalToConstant: 220).isActive = true
        topBar.addArrangedSubview(receiverSourceLabel)
        topBar.addArrangedSubview(receiverSourceNextButton)
        receiverConnectButton = NSButton(title: "Connect", target: self, action: #selector(toggleReceiver))
        topBar.addArrangedSubview(receiverConnectButton)
        receiverStatusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        receiverStatusLabel.lineBreakMode = .byTruncatingTail
        topBar.addArrangedSubview(receiverStatusLabel)

        let bottomBar = row()
        bottomBar.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 8, right: 10)
        receiverRecordButton = NSButton(title: "REC", target: self, action: #selector(toggleReceiverRecording))
        receiverTimerLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        receiverErrorLabel.textColor = .systemRed
        receiverErrorLabel.lineBreakMode = .byTruncatingMiddle
        bottomBar.addArrangedSubview(receiverRecordButton)
        bottomBar.addArrangedSubview(receiverTimerLabel)
        let slateLabel = NSTextField(labelWithString: "Slate")
        slateLabel.textColor = .secondaryLabelColor
        slateLabel.font = .systemFont(ofSize: 11)
        bottomBar.addArrangedSubview(slateLabel)
        receiverSlateField.target = self
        receiverSlateField.action = #selector(receiverSlateEdited)
        receiverSlateField.isContinuous = false
        receiverSlateField.placeholderString = "e.g. S14T3"
        receiverSlateField.widthAnchor.constraint(equalToConstant: 120).isActive = true
        bottomBar.addArrangedSubview(receiverSlateField)
        receiverAutoRecordCheckbox = NSButton(checkboxWithTitle: "Auto-record", target: self, action: #selector(receiverAutoRecordChanged))
        bottomBar.addArrangedSubview(receiverAutoRecordCheckbox)
        receiverAudioCheckbox = NSButton(checkboxWithTitle: "Audio", target: self, action: #selector(receiverAudioChanged))
        bottomBar.addArrangedSubview(receiverAudioCheckbox)
        bottomBar.addArrangedSubview(receiverErrorLabel)
        receiverFolderButton = button("Folder", action: #selector(revealRecordings), width: 64)
        bottomBar.addArrangedSubview(receiverFolderButton)
        receiverLockButton = button("🔓", action: #selector(toggleReceiverLock), width: 44)
        bottomBar.addArrangedSubview(receiverLockButton)

        let display = DisplayLayerHostNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 450))
        display.attach(displayLayer: receiverModel.displayLayer)
        display.widthAnchor.constraint(greaterThanOrEqualToConstant: 480).isActive = true
        display.heightAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true

        receiverTopBar = topBar
        receiverBottomBar = bottomBar
        root.addArrangedSubview(topBar)
        root.addArrangedSubview(bottomBar)
        root.addArrangedSubview(display)
        receiverWindow = makeWindow(title: "NDIStream - Receiver", content: root, size: NSSize(width: 820, height: 540))
        receiverWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        receiverWindow.level = .floating
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(receiverDidEnterFullScreen),
                                               name: NSWindow.didEnterFullScreenNotification,
                                               object: receiverWindow)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(receiverDidExitFullScreen),
                                               name: NSWindow.didExitFullScreenNotification,
                                               object: receiverWindow)
    }

    @objc private func receiverDidEnterFullScreen() {
        receiverTopBar?.isHidden = true
        receiverBottomBar?.isHidden = true
        DebugLog.write("receiver entered fullscreen — bars hidden")
    }

    @objc private func receiverDidExitFullScreen() {
        receiverTopBar?.isHidden = false
        receiverBottomBar?.isHidden = false
        DebugLog.write("receiver exited fullscreen — bars shown")
    }

    private func bindUpdates() {
        senderController.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateSenderUI() }
        }.store(in: &cancellables)
        senderController.recorder.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateSenderUI() }
        }.store(in: &cancellables)
        receiverModel.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateReceiverUI() }
        }.store(in: &cancellables)
        receiverModel.recorder.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateReceiverUI() }
        }.store(in: &cancellables)
    }

    private func updateSenderUI() {
        cameraLabel.stringValue = selectedCameraName
        sourceNameField.stringValue = senderController.sourceName
        if senderSlateField.stringValue != senderController.slate {
            senderSlateField.stringValue = senderController.slate
        }
        qualityControl.selectedSegment = QualityPreset.allCases.firstIndex(of: senderController.quality) ?? 0
        fpsControl.selectedSegment = senderController.targetFPS == 60 ? 1 : 0
        pixelFormatControl.selectedSegment = CapturePixelFormat.allCases.firstIndex(of: senderController.pixelFormat) ?? 0
        senderAudioLabel.stringValue = selectedAudioDeviceName
        senderAudioCheckbox.state = senderController.audioEnabled ? .on : .off
        pacingCheckbox.state = senderController.smoothPacing ? .on : .off
        lowestLatencyCheckbox.state = senderController.lowestLatency ? .on : .off
        lowestLatencyPendingLabel.isHidden = !senderController.lowestLatencyRelaunchRequired
        senderAutoRecordCheckbox.state = senderController.autoRecord ? .on : .off

        let locked = senderController.isLocked
        senderCameraPrevButton.isEnabled = !locked
        senderCameraNextButton.isEnabled = !locked
        senderAudioPrevButton.isEnabled = !locked && !senderController.isBroadcasting && senderController.availableAudioDevices.count > 1
        senderAudioNextButton.isEnabled = !locked && !senderController.isBroadcasting && senderController.availableAudioDevices.count > 1
        senderAudioCheckbox.isEnabled = !locked && !senderController.isBroadcasting && !senderController.availableAudioDevices.isEmpty
        sourceNameField.isEnabled = !locked && !senderController.isBroadcasting
        senderSlateField.isEnabled = !locked
        qualityControl.isEnabled = !locked
        fpsControl.isEnabled = !locked
        pixelFormatControl.isEnabled = !locked
        pacingCheckbox.isEnabled = !locked && !senderController.lowestLatency
        lowestLatencyCheckbox.isEnabled = !locked
        senderAutoRecordCheckbox.isEnabled = !locked
        senderRecordButton.isEnabled = !locked && senderController.isBroadcasting
        senderRecordButton.title = senderController.recorder.isRecording ? "STOP REC" : "REC"
        senderTimerLabel.stringValue = formatElapsed(senderController.recorder.elapsed)
        senderErrorLabel.stringValue = senderController.recorder.lastError ?? ""
        broadcastButton.isEnabled = !locked && !senderController.isTransitioning && !senderController.availableCameras.isEmpty
        broadcastButton.title = senderController.isBroadcasting ? "Stop Broadcasting" : "Start Broadcasting"
        senderLockButton.title = locked ? "🔒" : "🔓"
        senderLockButton.toolTip = locked ? "Unlock controls" : "Lock controls (prevents accidental clicks)"
        senderStatusLabel.stringValue = senderStatusText
        senderStatusDot.layer?.backgroundColor = senderStatusColor.cgColor
        updateStatusMenu()
    }

    private func updateReceiverUI() {
        receiverSourceLabel.stringValue = selectedSourceLabel
        receiverConnectButton.title = receiverModel.isConnected ? "Disconnect" : "Connect"
        let sourceOnline = receiverModel.availableSources.contains(where: { $0.name == receiverModel.selectedSourceName })
        receiverStatusLabel.stringValue = receiverModel.statusLine
        if receiverSlateField.stringValue != receiverModel.slate {
            receiverSlateField.stringValue = receiverModel.slate
        }
        receiverAutoRecordCheckbox.state = receiverModel.autoRecord ? .on : .off
        receiverAudioCheckbox.state = receiverModel.audioEnabled ? .on : .off
        receiverTallyDot.layer?.backgroundColor = receiverTallyColor.cgColor
        receiverTallyDot.toolTip = receiverTallyTooltip

        let locked = receiverModel.isLocked
        receiverSourcePrevButton.isEnabled = !locked && !receiverModel.isConnected
        receiverSourceNextButton.isEnabled = !locked && !receiverModel.isConnected
        receiverConnectButton.isEnabled = !locked && (receiverModel.isConnected || sourceOnline)
        receiverSlateField.isEnabled = !locked
        receiverAutoRecordCheckbox.isEnabled = !locked
        receiverAudioCheckbox.isEnabled = !locked
        receiverRecordButton.isEnabled = !locked && receiverModel.isConnected
        receiverRecordButton.title = receiverModel.recorder.isRecording ? "STOP REC" : "REC"
        receiverTimerLabel.stringValue = formatElapsed(receiverModel.recorder.elapsed)
        receiverErrorLabel.stringValue = receiverModel.recorder.lastError ?? ""
        receiverLockButton.title = locked ? "🔒" : "🔓"
        receiverLockButton.toolTip = locked ? "Unlock controls" : "Lock controls (prevents accidental clicks)"
        updateStatusMenu()
    }

    private var receiverTallyColor: NSColor {
        switch receiverModel.tally {
        case .idle: return .systemGray
        case .waiting: return .systemYellow
        case .live: return .systemGreen
        case .reconnecting: return .systemOrange
        }
    }

    private var receiverTallyTooltip: String {
        switch receiverModel.tally {
        case .idle: return "Idle"
        case .waiting: return "Connecting…"
        case .live: return "Receiving"
        case .reconnecting: return "Reconnecting"
        }
    }

    private func updateStatusMenu() {
        guard statusItem != nil else { return }
        statusItem.button?.title = senderController.isBroadcasting || receiverModel.isConnected ? "NDI ●" : "NDI"
        statusLineItem.title = statusSummary
        statusBroadcastItem.title = senderController.isBroadcasting ? "Stop Broadcasting" : "Start Broadcasting"
        statusBroadcastItem.isEnabled = !senderController.isTransitioning && !senderController.availableCameras.isEmpty
        statusReceiverItem.title = receiverModel.isConnected ? "Disconnect Receiver" : "Connect Receiver"
        statusReceiverItem.isEnabled = receiverModel.isConnected || receiverModel.availableSources.contains(where: { $0.name == receiverModel.selectedSourceName })
        statusSenderWindowItem.isEnabled = senderWindow != nil
        statusReceiverWindowItem.isEnabled = receiverWindow != nil
        statusHideWindowsItem.isEnabled = senderWindow?.isVisible == true || receiverWindow?.isVisible == true
    }

    @objc private func previousCamera() { selectCamera(offset: -1) }
    @objc private func nextCamera() { selectCamera(offset: 1) }
    @objc private func previousAudioDevice() { selectAudioDevice(offset: -1) }
    @objc private func nextAudioDevice() { selectAudioDevice(offset: 1) }
    @objc private func sourceNameEdited() { senderController.sourceName = sourceNameField.stringValue }
    @objc private func qualityChanged() { senderController.quality = QualityPreset.allCases[max(0, qualityControl.selectedSegment)] }
    @objc private func fpsChanged() { senderController.targetFPS = fpsControl.selectedSegment == 1 ? 60 : 30 }
    @objc private func pixelFormatChanged() { senderController.pixelFormat = CapturePixelFormat.allCases[max(0, pixelFormatControl.selectedSegment)] }
    @objc private func pacingChanged() { senderController.smoothPacing = pacingCheckbox.state == .on }
    @objc private func lowestLatencyChanged() { senderController.lowestLatency = lowestLatencyCheckbox.state == .on }
    @objc private func toggleBroadcast() { senderController.isBroadcasting ? senderController.stop() : senderController.start() }
    @objc private func toggleBroadcastFromStatusItem() {
        toggleBroadcast()
        DebugLog.write("status item toggle broadcast")
    }
    @objc private func toggleSenderRecording() {
        if senderController.recorder.isRecording {
            senderController.recorder.stop()
        } else {
            senderController.recorder.start(slate: senderController.slate, includeAudio: senderController.audioEnabled)
        }
    }
    @objc private func senderSlateEdited() { senderController.slate = senderSlateField.stringValue }
    @objc private func senderAutoRecordChanged() { senderController.autoRecord = senderAutoRecordCheckbox.state == .on }
    @objc private func senderAudioChanged() {
        senderController.audioEnabled = senderAudioCheckbox.state == .on
        DebugLog.write("sender audio=\(senderController.audioEnabled)")
    }
    @objc private func toggleSenderLock() {
        senderController.isLocked.toggle()
        DebugLog.write("sender lock=\(senderController.isLocked)")
    }

    @objc private func toggleAdvanced() {
        let expanding = advancedDisclosureButton.state == .on
        advancedContainer.isHidden = !expanding
        advancedDisclosureButton.title = expanding
            ? "▾  Advanced (quality, frame rate, latency)"
            : "▸  Advanced (quality, frame rate, latency)"
        resizeSenderWindowToFitContent(animate: true)
        DebugLog.write("advanced expanded=\(expanding)")
    }

    private func resizeSenderWindowToFitContent(animate: Bool) {
        guard let window = senderWindow, let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        let target = view.fittingSize
        var frame = window.frame
        let currentContentHeight = window.contentRect(forFrameRect: frame).height
        let delta = target.height - currentContentHeight
        guard abs(delta) > 0.5 else { return }
        frame.size.height += delta
        frame.origin.y -= delta
        window.setFrame(frame, display: true, animate: animate)
    }
    @objc private func revealRecordings() { Recorder.revealRecordingsFolder() }
    @objc private func openLog() { NSWorkspace.shared.open(DebugLog.url) }
    @objc private func showSenderWindow() {
        senderWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateStatusMenu()
    }
    @objc private func showReceiverWindow() {
        receiverWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateStatusMenu()
    }
    @objc private func hideWindows() {
        senderWindow?.orderOut(nil)
        receiverWindow?.orderOut(nil)
        DebugLog.write("windows hidden from status item")
        updateStatusMenu()
    }

    @objc private func previousSource() { selectSource(offset: -1) }
    @objc private func nextSource() { selectSource(offset: 1) }
    @objc private func toggleReceiver() { receiverModel.isConnected ? receiverModel.disconnect() : receiverModel.connect() }
    @objc private func toggleReceiverFromStatusItem() {
        toggleReceiver()
        DebugLog.write("status item toggle receiver")
    }
    @objc private func toggleReceiverRecording() {
        if receiverModel.recorder.isRecording {
            receiverModel.recorder.stop()
        } else {
            receiverModel.recorder.start(slate: receiverModel.slate, includeAudio: true)
        }
    }
    @objc private func receiverSlateEdited() { receiverModel.slate = receiverSlateField.stringValue }
    @objc private func receiverAutoRecordChanged() { receiverModel.autoRecord = receiverAutoRecordCheckbox.state == .on }
    @objc private func receiverAudioChanged() {
        receiverModel.audioEnabled = receiverAudioCheckbox.state == .on
        DebugLog.write("receiver audio=\(receiverModel.audioEnabled)")
    }
    @objc private func toggleReceiverLock() {
        receiverModel.isLocked.toggle()
        DebugLog.write("receiver lock=\(receiverModel.isLocked)")
    }

    private func selectCamera(offset: Int) {
        let cameras = senderController.availableCameras
        guard cameras.count > 1 else { return }
        let current = cameras.firstIndex { $0.uniqueID == senderController.selectedCameraID } ?? 0
        let next = (current + offset + cameras.count) % cameras.count
        senderController.selectedCameraID = cameras[next].uniqueID
    }

    private func selectAudioDevice(offset: Int) {
        let devices = senderController.availableAudioDevices
        guard devices.count > 1, !senderController.isBroadcasting else { return }
        let current = devices.firstIndex { $0.uniqueID == senderController.selectedAudioDeviceID } ?? 0
        let next = (current + offset + devices.count) % devices.count
        senderController.selectedAudioDeviceID = devices[next].uniqueID
    }

    private func selectSource(offset: Int) {
        let sources = receiverModel.availableSources
        guard sources.count > 1, !receiverModel.isConnected else { return }
        let current = sources.firstIndex { $0.name == receiverModel.selectedSourceName } ?? 0
        let next = (current + offset + sources.count) % sources.count
        receiverModel.selectedSourceName = sources[next].name
    }

    private var selectedCameraName: String {
        if senderController.availableCameras.isEmpty { return "No cameras found" }
        return senderController.currentDevice()?.localizedName ?? senderController.availableCameras.first?.localizedName ?? "Camera unavailable"
    }

    private var selectedAudioDeviceName: String {
        if senderController.availableAudioDevices.isEmpty { return "No microphones found" }
        return senderController.currentAudioDevice()?.localizedName ?? senderController.availableAudioDevices.first?.localizedName ?? "Microphone unavailable"
    }

    private var selectedSourceLabel: String {
        if receiverModel.availableSources.isEmpty { return "No sources found" }
        if !receiverModel.selectedSourceName.isEmpty {
            if receiverModel.availableSources.contains(where: { $0.name == receiverModel.selectedSourceName }) {
                return receiverModel.selectedSourceName
            }
            return "\(receiverModel.selectedSourceName) (offline)"
        }
        return receiverModel.availableSources.first?.name ?? "No sources found"
    }

    private var senderStatusColor: NSColor {
        switch senderController.status {
        case .idle: return .systemGray
        case .live: return .systemGreen
        case .error: return .systemRed
        }
    }

    private var senderStatusText: String {
        switch senderController.status {
        case .idle: return "Idle"
        case .live(let w, let h, let fps):
            if w == 0 || h == 0 { return "Broadcasting as '\(senderController.sourceName)' - starting..." }
            return "Broadcasting as '\(senderController.sourceName)' - \(w)x\(h) @ \(fps) fps"
        case .error(let msg): return msg
        }
    }

    private var statusSummary: String {
        var parts: [String] = []
        if senderController.isBroadcasting {
            parts.append("Sending \(senderController.sourceName)")
        }
        if receiverModel.isConnected {
            parts.append("Receiving")
        }
        if parts.isEmpty {
            return "Idle"
        }
        return parts.joined(separator: " / ")
    }

    private func makeWindow(title: String, content: NSView, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = title
        window.contentView = content
        return window
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        return label
    }

    private func labeledRow(_ label: String, _ control: NSView) -> NSStackView {
        let stack = row()
        let l = sectionLabel(label)
        l.widthAnchor.constraint(equalToConstant: 80).isActive = true
        stack.addArrangedSubview(l)
        stack.addArrangedSubview(control)
        return stack
    }

    private func row() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func button(_ title: String, action: Selector, width: CGFloat) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        return button
    }

    private func formatElapsed(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

@main
enum Main {
    @MainActor private static var appDelegate: AppDelegate?

    @MainActor
    static func main() {
        DebugLog.reset()
        DebugLog.write("Main.main")
        let app = NSApplication.shared
        let delegate = AppDelegate()
        appDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
