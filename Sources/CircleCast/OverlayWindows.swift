import AppKit
import AVFoundation
import CircleCastCore

final class CameraPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    let face = CameraView(frame: .zero)
    var displayFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    var onGeometry: ((CGRect) -> Void)?
    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        level = .floating; hidesOnDeactivate = false
        isReleasedWhenClosed = false; contentView = face
        face.panel = self
    }
    func place(on display: CGRect) {
        displayFrame = display
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: "cameraFrame").map(NSRectFromString)
        let initial = saved ?? CGRect(x: display.maxX - 224, y: display.maxY - 224, width: 200, height: 200)
        updateFrame(initial)
    }
    func updateFrame(_ proposed: CGRect) {
        let result = OverlayGeometry.clamp(proposed, to: displayFrame)
        setFrame(result, display: true)
        UserDefaults.standard.set(NSStringFromRect(result), forKey: "cameraFrame")
        onGeometry?(OverlayGeometry.normalized(result, in: displayFrame))
    }
    func resize(to side: CGFloat) {
        updateFrame(CGRect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side))
    }
    func corner(_ index: Int) {
        let margin: CGFloat = 24, side = frame.width
        let x = index % 2 == 0 ? displayFrame.minX + margin : displayFrame.maxX - side - margin
        let y = index < 2 ? displayFrame.maxY - side - margin : displayFrame.minY + margin
        updateFrame(CGRect(x: x, y: y, width: side, height: side))
    }
    func attach(_ session: AVCaptureSession?) { face.attach(session) }
}

final class CameraView: NSView {
    weak var panel: CameraPanel?
    private var preview: AVCaptureVideoPreviewLayer?
    private var dragOffset = CGPoint.zero
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.11, blue: 0.17, alpha: 0.96).cgColor
        layer?.borderColor = NSColor.white.cgColor; layer?.borderWidth = 2; layer?.masksToBounds = true
        toolTip = "拖动头像；滚轮调整大小。开始录制后显示摄像头。"
    }
    required init?(coder: NSCoder) { fatalError() }
    func attach(_ session: AVCaptureSession?) {
        preview?.session = nil; preview?.removeFromSuperlayer(); preview = nil
        if let session {
            let p = AVCaptureVideoPreviewLayer(session: session); p.videoGravity = .resizeAspectFill
            if let connection = p.connection, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = true
            }
            layer?.addSublayer(p); preview = p; p.frame = bounds
        }
        needsDisplay = true
    }
    override func layout() { super.layout(); layer?.cornerRadius = bounds.width / 2; preview?.frame = bounds }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard preview == nil else { return }
        let text = "头像位置\n拖动 · 滚轮缩放"
        let p = NSMutableParagraphStyle(); p.alignment = .center
        text.draw(in: CGRect(x: 8, y: bounds.midY - 24, width: bounds.width - 16, height: 52),
                  withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white, .paragraphStyle: p])
    }
    override func mouseDown(with event: NSEvent) {
        guard let panel else { return }
        let point = NSEvent.mouseLocation; dragOffset = CGPoint(x: point.x - panel.frame.minX, y: point.y - panel.frame.minY)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let panel else { return }
        let point = NSEvent.mouseLocation
        panel.updateFrame(CGRect(x: point.x - dragOffset.x, y: point.y - dragOffset.y, width: panel.frame.width, height: panel.frame.height))
    }
    override func scrollWheel(with event: NSEvent) {
        guard let panel else { return }; panel.resize(to: panel.frame.width - event.scrollingDeltaY * 2)
    }
}

final class PromptPanel: NSPanel, NSWindowDelegate, NSTextViewDelegate {
    let textView = NSTextView()
    private let scroller = NSScrollView()
    private let play = NSButton(title: "▶ 滚动", target: nil, action: nil)
    private let speed = NSSlider(value: 35, minValue: 8, maxValue: 100, target: nil, action: nil)
    private var timer: Timer?
    private var lastTick = 0.0
    private var restoring = false
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    init() {
        super.init(contentRect: CGRect(x: 80, y: 80, width: 440, height: 250),
                   styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        level = .floating; hidesOnDeactivate = false; isReleasedWhenClosed = false
        minSize = CGSize(width: 350, height: 170); delegate = self
        let root = NSView(); root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.74).cgColor
        root.layer?.cornerRadius = 14; root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        contentView = root
        let header = PromptDragView(); header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        let title = NSTextField(labelWithString: "提词 · 拖动此处移动 · 拖边缘缩放")
        title.textColor = .white; title.font = .systemFont(ofSize: 11)
        title.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(title)
        let close = NSButton(title: "×", target: self, action: #selector(hidePrompt))
        close.isBordered = false; close.contentTintColor = .white
        close.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(close)
        scroller.translatesAutoresizingMaskIntoConstraints = false
        scroller.drawsBackground = false; scroller.hasVerticalScroller = true; scroller.autohidesScrollers = true
        textView.isRichText = false; textView.drawsBackground = false; textView.textColor = .white
        textView.insertionPointColor = .white; textView.font = .systemFont(ofSize: 26, weight: .medium)
        textView.textContainerInset = CGSize(width: 14, height: 12)
        textView.minSize = CGSize(width: 0, height: 0); textView.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]; textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = CGSize(width: 412, height: CGFloat.greatestFiniteMagnitude)
        textView.string = UserDefaults.standard.string(forKey: "promptText") ?? "把讲稿粘贴在这里。\n\n点击下方「滚动」开始；编辑文字会自动暂停。\n\n黑色半透明提词框只供你阅读，不会合成到视频中。"
        textView.delegate = self; scroller.documentView = textView; root.addSubview(scroller)
        play.target = self; play.action = #selector(toggleScroll)
        let reset = NSButton(title: "回顶部", target: self, action: #selector(resetScroll))
        let font = NSStepper(); font.minValue = 16; font.maxValue = 52; font.increment = 2
        font.doubleValue = UserDefaults.standard.double(forKey: "promptFont") == 0 ? 26 : UserDefaults.standard.double(forKey: "promptFont")
        font.target = self; font.action = #selector(changeFont(_:)); changeFont(font)
        speed.doubleValue = UserDefaults.standard.double(forKey: "promptSpeed") == 0 ? 35 : UserDefaults.standard.double(forKey: "promptSpeed")
        speed.target = self; speed.action = #selector(speedChanged)
        speed.toolTip = "滚动速度：每秒 8–100 点"
        let speedTitle = NSTextField(labelWithString: "速度")
        let fontTitle = NSTextField(labelWithString: "字号")
        for label in [speedTitle, fontTitle] { label.textColor = .white; label.font = .systemFont(ofSize: 11) }
        let bar = NSStackView(views: [play, reset, speedTitle, speed, fontTitle, font])
        bar.orientation = .horizontal; bar.spacing = 8; bar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bar)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor), header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor), header.heightAnchor.constraint(equalToConstant: 32),
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14), title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8), close.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            scroller.topAnchor.constraint(equalTo: header.bottomAnchor), scroller.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            scroller.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4), scroller.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -6),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12), bar.heightAnchor.constraint(equalToConstant: 28),
            speed.widthAnchor.constraint(greaterThanOrEqualToConstant: 48)
        ])
    }
    func show(below camera: CGRect, in screen: CGRect) {
        restoring = true
        if let saved = UserDefaults.standard.string(forKey: "promptFrame") { setFrame(NSRectFromString(saved), display: true) }
        else { setFrame(CGRect(x: camera.midX - 220, y: camera.minY - 266, width: 440, height: 250), display: true) }
        recoverToVisibleScreen(preferred: screen)
        restoring = false; saveGeometry(); orderFrontRegardless()
    }
    func recoverToVisibleScreen(preferred: CGRect) {
        let visible = NSScreen.screens.map(\.visibleFrame)
        let target = visible.first(where: { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) })
                     ?? visible.first(where: { $0.intersects(preferred) }) ?? preferred
        let width = min(max(minSize.width, frame.width), target.width)
        let height = min(max(minSize.height, frame.height), target.height)
        setFrame(CGRect(x: min(max(frame.minX, target.minX), target.maxX - width),
                        y: min(max(frame.minY, target.minY), target.maxY - height), width: width, height: height), display: true)
    }
    func pause() { timer?.invalidate(); timer = nil; play.title = "▶ 滚动" }
    @objc private func toggleScroll() {
        if timer != nil { pause(); return }
        textView.window?.makeFirstResponder(nil)
        lastTick = ProcessInfo.processInfo.systemUptime; play.title = "Ⅱ 暂停"
        let source = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        timer = source; RunLoop.main.add(source, forMode: .common)
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime, elapsed = min(0.1, now - lastTick); lastTick = now
        let clip = scroller.contentView
        let maxY = max(0, textView.bounds.height - clip.bounds.height)
        let y = min(maxY, clip.bounds.minY + elapsed * speed.doubleValue)
        clip.scroll(to: CGPoint(x: 0, y: y)); scroller.reflectScrolledClipView(clip)
        if y >= maxY { pause() }
    }
    @objc private func resetScroll() { pause(); scroller.contentView.scroll(to: .zero); scroller.reflectScrolledClipView(scroller.contentView) }
    @objc private func speedChanged() { UserDefaults.standard.set(speed.doubleValue, forKey: "promptSpeed") }
    @objc private func changeFont(_ sender: NSStepper) {
        textView.font = .systemFont(ofSize: CGFloat(sender.doubleValue), weight: .medium)
        UserDefaults.standard.set(sender.doubleValue, forKey: "promptFont")
    }
    @objc private func hidePrompt() { pause(); orderOut(nil); onClose?() }
    func textDidChange(_ notification: Notification) { pause(); UserDefaults.standard.set(textView.string, forKey: "promptText") }
    func windowDidMove(_ notification: Notification) { saveGeometry() }
    func windowDidResize(_ notification: Notification) { saveGeometry() }
    private func saveGeometry() { if !restoring { UserDefaults.standard.set(NSStringFromRect(frame), forKey: "promptFrame") } }
}
final class PromptDragView: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}
