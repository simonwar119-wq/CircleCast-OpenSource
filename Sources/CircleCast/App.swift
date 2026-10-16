import AppKit
import UniformTypeIdentifiers
import CircleCastCore

@main struct CircleCastApp {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--version") {
            print("CircleCast 0.1.0 · native macOS 14+ · local-only")
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let recorder = Recorder()
    private var window: NSWindow!
    private let camera = CameraPanel()
    private let prompt = PromptPanel()
    private let displays = NSPopUpButton()
    private let formats = NSPopUpButton()
    private let start = NSButton(title: "开始录制", target: nil, action: nil)
    private let stop = NSButton(title: "停止并导出", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "准备就绪。摄像头、麦克风未开启。")
    private let elapsed = NSTextField(labelWithString: "00:00")
    private let promptToggle = NSButton(checkboxWithTitle: "显示提词器（仅自己可见）", target: nil, action: nil)
    private var sizeSlider = NSSlider(value: 200, minValue: 96, maxValue: 480, target: nil, action: nil)
    private var screenChoices: [ScreenChoice] = []
    private var statusItem: NSStatusItem?
    private var pendingExport: URL?
    private var terminationRequested = false
    private var screenObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var takeScreenID: CGDirectDisplayID?
    private var takeFrame: CGRect?
    private var takePixelSize: CGSize?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu(); buildWindow(); connectRecorder(); refreshScreens()
        camera.onGeometry = { [weak self] rect in self?.recorder.overlay.set(rect); self?.sizeSlider.doubleValue = Double(self?.camera.frame.width ?? 200) }
        if let choice = currentScreen { camera.place(on: choice.frame) }
        prompt.onClose = { [weak self] in self?.promptToggle.state = .off }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screensChanged() }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.recorder.stop(reason: "Mac 进入睡眠，已结束本次录制。") }
        }
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private var currentScreen: ScreenChoice? {
        guard screenChoices.indices.contains(displays.indexOfSelectedItem) else { return nil }
        return screenChoices[displays.indexOfSelectedItem]
    }
    private func buildMenu() {
        let menu = NSMenu()
        let root = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于头像录屏", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出头像录屏", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        root.submenu = appMenu; menu.addItem(root)
        let edit = NSMenuItem(); let edits = NSMenu(title: "编辑")
        edits.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edits.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edits.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edits.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = edits; menu.addItem(edit); NSApp.mainMenu = menu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "◉ 头像录屏"
        let statusMenu = NSMenu()
        statusMenu.addItem(withTitle: "显示控制窗口", action: #selector(showWindow), keyEquivalent: "")
        statusMenu.addItem(withTitle: "停止录制", action: #selector(stopRecording), keyEquivalent: "")
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        for item in statusMenu.items { item.target = self }
        statusMenu.items.last?.target = NSApp; statusItem?.menu = statusMenu
    }
    @discardableResult func buildWindow() -> NSWindow {
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 590, height: 560), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "头像录屏 · CircleCast"; window.isReleasedWhenClosed = false; window.delegate = self
        let title = NSTextField(labelWithString: "屏幕 + 你的圆形头像")
        title.font = .systemFont(ofSize: 25, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: "本地录制，H.264 视频 + 麦克风声音。无网络、无订阅。")
        subtitle.textColor = .secondaryLabelColor
        displays.target = self; displays.action = #selector(displaySelected)
        formats.addItems(withTitles: ["MP4（推荐）", "MOV"])
        let displayRow = row([NSTextField(labelWithString: "录制屏幕"), displays, formats])
        let cameraButton = NSButton(title: "摆放头像", target: self, action: #selector(showCamera))
        let corners = NSPopUpButton(); corners.addItems(withTitles: ["快速放角落", "左上", "右上", "左下", "右下"])
        corners.target = self; corners.action = #selector(cornerSelected(_:))
        let avatarRow = row([cameraButton, NSTextField(labelWithString: "大小"), sizeSlider, corners])
        sizeSlider.target = self; sizeSlider.action = #selector(sizeChanged)
        sizeSlider.widthAnchor.constraint(equalToConstant: 130).isActive = true
        promptToggle.target = self; promptToggle.action = #selector(togglePrompt)
        let promptHelp = NSTextField(wrappingLabelWithString: "提词框可单独拖动、缩放、粘贴讲稿；文字默认不会进入视频。")
        promptHelp.font = .systemFont(ofSize: 12); promptHelp.textColor = .secondaryLabelColor
        let privacy = NSTextField(wrappingLabelWithString: "点击开始才会申请并启用摄像头、麦克风和录屏。\n请先结束私人通话；3 秒倒计时后录制所选整个屏幕。")
        privacy.font = .systemFont(ofSize: 12)
        elapsed.font = .monospacedDigitSystemFont(ofSize: 28, weight: .medium)
        start.bezelStyle = .rounded; start.controlSize = .large; start.keyEquivalent = "\r"
        start.target = self; start.action = #selector(startRecording)
        stop.bezelStyle = .rounded; stop.controlSize = .large; stop.target = self; stop.action = #selector(stopRecording); stop.isEnabled = false
        let actions = row([start, stop, elapsed])
        status.font = .systemFont(ofSize: 12); status.maximumNumberOfLines = 4
        let recover = NSButton(title: "打开录制暂存文件夹", target: self, action: #selector(openRecordings))
        let stack = NSStackView(views: [title, subtitle, displayRow, avatarRow, promptToggle, promptHelp, privacy, actions, status, recover])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 17
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 28),
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -24),
            status.widthAnchor.constraint(equalToConstant: 534),
            displays.widthAnchor.constraint(equalToConstant: 260)
        ])
        return window
    }
    private func row(_ views: [NSView]) -> NSStackView {
        let result = NSStackView(views: views); result.orientation = .horizontal; result.spacing = 12; return result
    }
    private func connectRecorder() {
        recorder.onStatus = { [weak self] phase, text in
            guard let self else { return }
            status.stringValue = text
            let idle = phase == .idle
            start.isEnabled = idle && !screenChoices.isEmpty; displays.isEnabled = idle; formats.isEnabled = idle
            stop.isEnabled = !idle && phase != .stopping
            stop.title = phase == .recording ? "停止并导出" : "取消启动"
            statusItem?.button?.title = phase == .recording ? "🔴 正在录制" : "◉ 头像录屏"
            if idle {
                prompt.pause(); takeScreenID = nil; takeFrame = nil; takePixelSize = nil
                if terminationRequested { NSApp.reply(toApplicationShouldTerminate: true) }
            }
        }
        recorder.onCountdown = { [weak self] number in self?.elapsed.stringValue = "\(number)…" }
        recorder.onPreview = { [weak self] session in
            guard let self else { return }; camera.attach(session)
            if session != nil { camera.orderFrontRegardless() }
            else { camera.orderOut(nil) }
        }
        recorder.onProgress = { [weak self] seconds, mic in
            self?.elapsed.stringValue = String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
            if !mic { self?.status.stringValue = "麦克风暂未返回数据，正在检查…" }
        }
        recorder.onFinished = { [weak self] url, stats, warning in
            guard let self else { return }
            if let stats {
                let audioWarning = stats.audioBuffers == 0 ? "未写入麦克风数据，请检查声音后再使用视频。" : nil
                let loadWarning: String? = (stats.droppedVideoFrames > 0 || stats.droppedAudioBuffers > 0)
                    ? "编码繁忙：丢弃了 \(stats.droppedVideoFrames) 个视频帧 / \(stats.droppedAudioBuffers) 段音频，请检查播放效果。" : nil
                let details = [warning, audioWarning, loadWarning].compactMap { $0 }.joined(separator: "\n")
                status.stringValue = "已完成 \(String(format: "%.1f", stats.duration)) 秒；\(stats.videoFrames) 帧，音频 \(stats.audioBuffers) 段。" + (details.isEmpty ? "" : "\n" + details)
                pendingExport = url
                if !terminationRequested { export(url) }
            } else {
                status.stringValue = (warning ?? "视频保存失败。") + "\n若存在未完成文件，保留在暂存文件夹。"
            }
        }
    }
    private func refreshScreens() {
        let previous = currentScreen?.id
        screenChoices = ScreenChoice.available(); displays.removeAllItems()
        for (index, screen) in screenChoices.enumerated() {
            displays.addItem(withTitle: "\(index + 1). \(screen.name) · \(Int(screen.pixelSize.width))×\(Int(screen.pixelSize.height))")
        }
        if let index = screenChoices.firstIndex(where: { $0.id == previous }) { displays.selectItem(at: index) }
        start.isEnabled = recorder.phase == .idle && !screenChoices.isEmpty
    }
    @objc private func displaySelected() {
        guard let screen = currentScreen else { return }
        camera.place(on: screen.frame); prompt.recoverToVisibleScreen(preferred: screen.frame)
    }
    private func screensChanged() {
        let choices = ScreenChoice.available()
        if recorder.phase != .idle, let id = takeScreenID {
            if let chosen = choices.first(where: { $0.id == id }), chosen.frame == takeFrame, chosen.pixelSize == takePixelSize {
                // A different display may have changed; selected capture geometry is still valid.
            } else { recorder.stop(reason: "录制屏幕断开或布局/分辨率改变，已停止以避免画面错位。") }
        }
        refreshScreens()
        if recorder.phase == .idle, let screen = currentScreen { camera.place(on: screen.frame) }
        prompt.recoverToVisibleScreen(preferred: currentScreen?.frame ?? NSScreen.main?.frame ?? .zero)
    }
    @objc private func startRecording() {
        guard recorder.phase == .idle, let screen = currentScreen else { return }
        do {
            let folder = try recordingFolder()
            let ext = formats.indexOfSelectedItem == 1 ? "mov" : "mp4"
            let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let url = folder.appendingPathComponent("CircleCast_\(stamp.string(from: Date()))_\(UUID().uuidString.prefix(6)).\(ext)")
            camera.place(on: screen.frame); takeScreenID = screen.id; takeFrame = screen.frame; takePixelSize = screen.pixelSize
            elapsed.stringValue = "00:00"; recorder.start(screen: screen, output: url)
        } catch { status.stringValue = "无法创建录制目录：\(error.localizedDescription)" }
    }
    @objc private func stopRecording() { recorder.stop() }
    @objc private func showCamera() {
        guard let screen = currentScreen else { return }; camera.place(on: screen.frame); camera.orderFrontRegardless()
    }
    @objc private func sizeChanged() { camera.resize(to: CGFloat(sizeSlider.doubleValue)); camera.orderFrontRegardless() }
    @objc private func cornerSelected(_ sender: NSPopUpButton) {
        guard sender.indexOfSelectedItem > 0 else { return }; camera.corner(sender.indexOfSelectedItem - 1)
        camera.orderFrontRegardless(); sender.selectItem(at: 0)
    }
    @objc private func togglePrompt() {
        if promptToggle.state == .on, let screen = currentScreen { prompt.show(below: camera.frame, in: screen.frame) }
        else { prompt.pause(); prompt.orderOut(nil) }
    }
    private func recordingFolder() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("CircleCast/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    private func export(_ source: URL) {
        let panel = NSSavePanel(); panel.title = "导出录制视频"
        panel.nameFieldStringValue = source.lastPathComponent
        panel.allowedContentTypes = [source.pathExtension == "mov" ? .quickTimeMovie : .mpeg4Movie]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let target = panel.url else {
                self.status.stringValue = "已保留录制，可从「打开录制暂存文件夹」找回并导出。"; return
            }
            // Only the explicitly chosen file may be replaced. Keep the original take until copying succeeds.
            Task.detached {
                do {
                    if target.standardizedFileURL != source.standardizedFileURL {
                        if FileManager.default.fileExists(atPath: target.path) {
                            let staging = target.deletingLastPathComponent().appendingPathComponent(".circlecast-export-\(UUID().uuidString).\(source.pathExtension)")
                            try FileManager.default.copyItem(at: source, to: staging)
                            defer { try? FileManager.default.removeItem(at: staging) }
                            _ = try FileManager.default.replaceItemAt(target, withItemAt: staging)
                        } else { try FileManager.default.copyItem(at: source, to: target) }
                    }
                    await MainActor.run { self.status.stringValue = "已导出：\(target.path)\n原始录制仍保留在暂存文件夹，可自行清理。"; self.pendingExport = nil }
                } catch {
                    await MainActor.run { self.status.stringValue = "导出失败：\(error.localizedDescription)\n原始录制已保留，可重新复制。" }
                }
            }
        }
    }
    @objc private func openRecordings() {
        do { NSWorkspace.shared.open(try recordingFolder()) }
        catch { status.stringValue = error.localizedDescription }
    }
    @objc private func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func showAbout() {
        let alert = NSAlert(); alert.messageText = "头像录屏 · CircleCast 0.1"
        alert.informativeText = "原生轻量本地 MVP\n一块屏幕 + 内置摄像头 + 默认麦克风\n提词器仅自己可见；30 fps，最长边最高 1920。\n\n本机临时签名，未公证，不适合作为公开分发包。"
        alert.runModal()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if recorder.phase != .idle { recorder.stop(); status.stringValue = "正在停止录制。完成后可关闭窗口。"; return false }
        camera.orderOut(nil); prompt.pause(); prompt.orderOut(nil); promptToggle.state = .off
        return true
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        prompt.pause()
        guard recorder.phase != .idle else { return .terminateNow }
        terminationRequested = true; recorder.stop(); return .terminateLater
    }
}
