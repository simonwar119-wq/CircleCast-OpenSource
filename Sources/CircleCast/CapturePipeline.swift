import Foundation
import AVFoundation
import ScreenCaptureKit
import CircleCastCore

/// All media callbacks, timer ticks and writer access run on queue.
final class CapturePipeline: NSObject, SCStreamOutput, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "local.circlecast.media", qos: .userInitiated)
    let overlay: OverlayState
    private var screen: CVPixelBuffer?
    private var camera: CVPixelBuffer?
    private var writer: MovieWriter?
    private var compositor: CircleCompositor?
    private var timer: DispatchSourceTimer?
    private var accepting = false
    private var lastCameraArrival: Double = 0
    private var lastAudioArrival: Double = 0
    private var began: Double = 0
    private var audioClock: CMClock?
    private var reportedFailure = false
    var onFailure: ((Error) -> Void)?
    var onProgress: ((Double, Bool) -> Void)?
    private var progressTick = 0
    init(overlay: OverlayState) { self.overlay = overlay }
    func prepare(url: URL, width: Int, height: Int, clock: CMClock?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    writer = try MovieWriter(url: url, width: width, height: height)
                    compositor = CircleCompositor()
                    audioClock = clock; accepting = true; reportedFailure = false
                    began = ProcessInfo.processInfo.systemUptime
                    lastCameraArrival = began; lastAudioArrival = began
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func beginTicks() {
        queue.async { [self] in
            guard accepting, timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .nanoseconds(33_333_333), leeway: .milliseconds(2))
            source.setEventHandler { [weak self] in self?.tick() }
            timer = source; source.resume()
        }
    }
    func quiesce() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                accepting = false; timer?.cancel(); timer = nil
                continuation.resume()
            }
        }
    }
    func finish() async throws -> MovieStats {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard let writer else { continuation.resume(throwing: MovieError.message("没有待完成的视频。")); return }
                writer.finish { result in continuation.resume(with: result) }
                self.writer = nil; screen = nil; camera = nil; compositor = nil; audioClock = nil
            }
        }
    }
    func discard() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                accepting = false; timer?.cancel(); timer = nil; writer?.cancel(); writer = nil
                screen = nil; camera = nil; compositor = nil; audioClock = nil
                continuation.resume()
            }
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard accepting, type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        screen = image
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard accepting, sampleBuffer.isValid else { return }
        if output is AVCaptureVideoDataOutput {
            camera = CMSampleBufferGetImageBuffer(sampleBuffer)
            lastCameraArrival = ProcessInfo.processInfo.systemUptime
        } else if output is AVCaptureAudioDataOutput {
            lastAudioArrival = ProcessInfo.processInfo.systemUptime
            guard let writer, writer.hasStarted else { return }
            do {
                let translated = try hostTimed(sampleBuffer)
                try writer.appendAudio(translated)
            } catch { fail(error) }
        }
    }
    private func hostTimed(_ sample: CMSampleBuffer) throws -> CMSampleBuffer {
        guard let audioClock else { return sample }
        var count = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid), count: count)
        let readStatus = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count)
        guard readStatus == noErr, count > 0 else { throw MovieError.message("无法读取麦克风时间戳。") }
        for i in timings.indices {
            timings[i].presentationTimeStamp = CMSyncConvertTime(timings[i].presentationTimeStamp, from: audioClock, to: CMClockGetHostTimeClock())
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp = CMSyncConvertTime(timings[i].decodeTimeStamp, from: audioClock, to: CMClockGetHostTimeClock())
            }
        }
        var copied: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: count, sampleTimingArray: &timings, sampleBufferOut: &copied)
        guard status == noErr, let copied else { throw MovieError.message("麦克风时间戳同步失败。") }
        return copied
    }
    private func tick() {
        guard accepting, let writer else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Static screens legitimately stop delivering screen frames. Camera/mic must remain live.
        if now - began > 8, screen == nil { fail(MovieError.message("8 秒内没有收到屏幕画面，请检查录屏权限。")); return }
        if now - lastCameraArrival > 5 { fail(MovieError.message("摄像头中断或被其他应用占用，录制已停止。")); return }
        if now - lastAudioArrival > 5 { fail(MovieError.message("麦克风中断，录制已停止。")); return }
        guard let screen, let camera, let compositor else { return }
        do {
            // Recompose at 30 fps even if the desktop is static, so the face keeps moving.
            let output = try writer.pixelBuffer()
            compositor.render(screen: screen, camera: camera, normalizedRect: overlay.get(), into: output)
            try writer.appendVideo(output, at: CMClockGetTime(CMClockGetHostTimeClock()))
            progressTick += 1
            if progressTick % 15 == 0 { onProgress?(now - began, now - lastAudioArrival < 1) }
        } catch { fail(error) }
    }
    private func fail(_ error: Error) {
        guard !reportedFailure else { return }; reportedFailure = true; accepting = false
        timer?.cancel(); timer = nil
        onFailure?(error)
    }
}
