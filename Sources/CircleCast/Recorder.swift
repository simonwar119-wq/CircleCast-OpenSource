import AppKit
@preconcurrency import AVFoundation
import ScreenCaptureKit
import CircleCastCore

struct ScreenChoice {
    let id: CGDirectDisplayID
    let name: String
    let frame: CGRect
    let pixelSize: CGSize
    static func available() -> [ScreenChoice] {
        NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            return ScreenChoice(id: id, name: screen.localizedName, frame: screen.frame,
                                pixelSize: CGSize(width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id)))
        }
    }
}

@MainActor final class Recorder: NSObject, SCStreamDelegate {
    private(set) var lifecycle = RecordingLifecycle()
    var phase: RecorderPhase { lifecycle.phase }
    var onStatus: ((RecorderPhase, String) -> Void)?
    var onPreview: ((AVCaptureSession?) -> Void)?
    var onFinished: ((URL, MovieStats?, String?) -> Void)?
    var onProgress: ((Double, Bool) -> Void)?
    var onCountdown: ((Int) -> Void)?
    let overlay = OverlayState()
    private var startTask: Task<Void, Never>?
    private var stream: SCStream?
    private var session: AVCaptureSession?
    private var pipeline: CapturePipeline?
    private var outputURL: URL?
    private var interruptionTokens: [NSObjectProtocol] = []
    private let deviceQueue = DispatchQueue(label: "local.circlecast.devices", qos: .userInitiated)
    private var cancelRequested = false
    private var startupFailure: Error?

    func start(screen: ScreenChoice, output: URL) {
        guard lifecycle.begin() else { return }
        outputURL = output; cancelRequested = false; startupFailure = nil
        notify("仅在本次开始操作后申请权限…")
        startTask = Task { [self] in
            do {
                try await authorize(.video, name: "摄像头")
                try Task.checkCancellation()
                try await authorize(.audio, name: "麦克风")
                try Task.checkCancellation()
                if !CGPreflightScreenCaptureAccess() {
                    let granted = CGRequestScreenCaptureAccess()
                    guard granted else { throw MovieError.message("屏幕录制未获授权。请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中开启“头像录屏”，再退出并重新打开 App。") }
                }
                try Task.checkCancellation()
                lifecycle.advance(.countdown)
                for remaining in stride(from: 3, through: 1, by: -1) {
                    notify("\(remaining) 秒后录制；请先结束私人通话并切换到要展示的内容。")
                    onCountdown?(remaining)
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                lifecycle.advance(.preparing); notify("正在启动设备…")
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                try Task.checkCancellation()
                guard let display = content.displays.first(where: { $0.displayID == screen.id }) else {
                    throw MovieError.message("选定的显示器已断开，请重新选择。")
                }
                // Exclude the entire application: camera preview, prompt, controls, dialogs, and future windows.
                let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                guard !ownApps.isEmpty else { throw MovieError.message("无法确认本应用的录屏排除范围；为避免录入提词，已取消。请重新打开 App。") }
                let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
                let size = OverlayGeometry.outputSize(for: screen.pixelSize)
                let config = SCStreamConfiguration()
                config.width = size.0; config.height = size.1
                config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                config.pixelFormat = kCVPixelFormatType_32BGRA; config.queueDepth = 3
                config.showsCursor = true; config.capturesAudio = false
                config.colorSpaceName = CGColorSpace.sRGB
                config.captureResolution = .best
                let media = CapturePipeline(overlay: overlay)
                pipeline = media
                media.onFailure = { [weak self] error in Task { @MainActor in self?.interrupted(error) } }
                media.onProgress = { [weak self] seconds, mic in Task { @MainActor in self?.onProgress?(seconds, mic) } }
                let capture = try await configureDevices(media)
                session = capture
                try Task.checkCancellation()
                watchSession(capture)
                onPreview?(capture)
                try await runDevices(capture)
                try Task.checkCancellation()
                if let startupFailure { throw startupFailure }
                try await media.prepare(url: output, width: size.0, height: size.1, clock: capture.synchronizationClock)
                try Task.checkCancellation()
                let newStream = SCStream(filter: filter, configuration: config, delegate: self)
                stream = newStream
                try newStream.addStreamOutput(media, type: .screen, sampleHandlerQueue: media.queue)
                try await newStream.startCapture()
                try Task.checkCancellation()
                if let startupFailure { throw startupFailure }
                lifecycle.advance(.recording); notify("正在录制 · 圆形头像与麦克风会写入视频")
                media.beginTicks()
                startTask = nil
            } catch {
                let cancelled = cancelRequested
                if phase != .stopping { lifecycle.advance(.stopping) }
                notify("正在释放设备…")
                await releaseDevices()
                await pipeline?.discard(); pipeline = nil
                // A failed/cancelled start has no useful recording; only remove this run's newly created temporary file.
                if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
                outputURL = nil; startTask = nil
                lifecycle.advance(.idle)
                notify(cancelled ? "已取消；摄像头、麦克风和录屏已关闭。" : "启动失败：\((startupFailure ?? error).localizedDescription)")
            }
        }
    }
    func stop(reason: String? = nil) {
        guard phase != .idle, phase != .stopping else { return }
        if phase != .recording {
            cancelRequested = reason == nil
            if let reason { startupFailure = MovieError.message(reason) }
            lifecycle.advance(.stopping); notify("正在取消启动并释放设备…")
            startTask?.cancel()
            return
        }
        lifecycle.advance(.stopping); notify("正在停止并完成视频文件…")
        Task { [self] in
            await releaseDevices()
            let url = outputURL
            do {
                let stats = try await pipeline?.finish()
                pipeline = nil; outputURL = nil
                lifecycle.advance(.idle); notify("已停止；摄像头、麦克风和录屏已关闭。")
                if let url { onFinished?(url, stats, reason) }
            } catch {
                pipeline = nil; outputURL = nil
                lifecycle.advance(.idle); notify("已停止并释放设备。视频保存失败：\(error.localizedDescription)")
                // Preserve any partial file for inspection; never silently remove a recorded take.
                if let url { onFinished?(url, nil, "视频未完成：\(error.localizedDescription)") }
            }
        }
    }
    private func authorize(_ type: AVMediaType, name: String) async throws {
        let status = AVCaptureDevice.authorizationStatus(for: type)
        if status == .authorized { return }
        if status == .notDetermined, await AVCaptureDevice.requestAccess(for: type) { return }
        throw MovieError.message("\(name)未获授权。请在系统设置 → 隐私与安全性 → \(name)中开启“头像录屏”，然后重试。")
    }
    private func configureDevices(_ media: CapturePipeline) async throws -> AVCaptureSession {
        try await withCheckedThrowingContinuation { continuation in
            deviceQueue.async {
                do {
                    let capture = AVCaptureSession()
                    capture.beginConfiguration()
                    var committed = false
                    defer { if !committed { capture.commitConfiguration() } }
                    if capture.canSetSessionPreset(.hd1280x720) { capture.sessionPreset = .hd1280x720 }
                    let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)
                    guard let camera = discovery.devices.first else { throw MovieError.message("未找到 Mac 内置摄像头。此轻量版不会自动选择手机或虚拟摄像头。") }
                    guard let mic = AVCaptureDevice.default(for: .audio) else { throw MovieError.message("未找到默认麦克风，请在系统声音设置中选择输入设备。") }
                    for device in [camera, mic] {
                        let input = try AVCaptureDeviceInput(device: device)
                        guard capture.canAddInput(input) else { throw MovieError.message("无法打开 \(device.localizedName)，可能被其他应用占用。") }
                        capture.addInput(input)
                    }
                    let video = AVCaptureVideoDataOutput()
                    video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    video.alwaysDiscardsLateVideoFrames = true
                    video.setSampleBufferDelegate(media, queue: media.queue)
                    let audio = AVCaptureAudioDataOutput()
                    audio.setSampleBufferDelegate(media, queue: media.queue)
                    guard capture.canAddOutput(video), capture.canAddOutput(audio) else { throw MovieError.message("无法配置摄像头与麦克风输出。") }
                    capture.addOutput(video); capture.addOutput(audio)
                    if let connection = video.connection(with: .video), connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false
                    }
                    capture.commitConfiguration(); committed = true
                    continuation.resume(returning: capture)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func runDevices(_ capture: AVCaptureSession) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            deviceQueue.async {
                capture.startRunning()
                if capture.isRunning { continuation.resume() }
                else { continuation.resume(throwing: MovieError.message("摄像头或麦克风无法启动。请结束占用设备的通话后再试。")) }
            }
        }
    }
    private func releaseDevices() async {
        await pipeline?.quiesce()
        if let stream {
            do { try await stream.stopCapture() } catch { /* Capture may already have stopped after revocation. */ }
            if let pipeline { try? stream.removeStreamOutput(pipeline, type: .screen) }
            self.stream = nil
        }
        onPreview?(nil)
        for token in interruptionTokens { NotificationCenter.default.removeObserver(token) }
        interruptionTokens.removeAll()
        if let capture = session {
            await withCheckedContinuation { continuation in
                deviceQueue.async {
                    capture.stopRunning()
                    for output in capture.outputs {
                        (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
                        (output as? AVCaptureAudioDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
                        capture.removeOutput(output)
                    }
                    for input in capture.inputs { capture.removeInput(input) }
                    continuation.resume()
                }
            }
            session = nil
        }
    }
    private func watchSession(_ capture: AVCaptureSession) {
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            interruptionTokens.append(NotificationCenter.default.addObserver(forName: name, object: capture, queue: .main) { [weak self] note in
                let detail = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "摄像头或麦克风被系统中断。"
                Task { @MainActor in self?.interrupted(MovieError.message(detail)) }
            })
        }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in self?.interrupted(error) }
    }
    private func interrupted(_ error: Error) {
        if phase == .recording { stop(reason: error.localizedDescription) }
        else if phase == .preparing { startupFailure = error; startTask?.cancel() }
    }
    private func notify(_ text: String) { onStatus?(phase, text) }
}
