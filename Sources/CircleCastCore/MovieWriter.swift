import Foundation
import AVFoundation
import CoreVideo

public enum MovieError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
public struct MovieStats {
    public let videoFrames: Int
    public let audioBuffers: Int
    public let droppedVideoFrames: Int
    public let droppedAudioBuffers: Int
    public let duration: Double
}

/// Confined to one serial media queue. Timestamps must use the host clock.
public final class MovieWriter {
    public let url: URL
    public let width: Int
    public let height: Int
    public let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var startTime: CMTime?
    private var lastVideo: CMTime?
    private var lastAudio: CMTime?
    private var endTime: CMTime?
    private var finishing = false
    private var videoFrames = 0, audioBuffers = 0, droppedVideo = 0, droppedAudio = 0
    public var hasStarted: Bool { startTime != nil }
    public var videoReady: Bool { video.isReadyForMoreMediaData }
    public var audioReady: Bool { audio.isReadyForMoreMediaData }
    public init(url: URL, width: Int, height: Int, realtime: Bool = true) throws {
        self.url = url; self.width = width; self.height = height
        writer = try AVAssetWriter(outputURL: url, fileType: url.pathExtension.lowercased() == "mov" ? .mov : .mp4)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(800_000, width * height * 4),
                                              AVVideoExpectedSourceFrameRateKey: 30,
                                              AVVideoMaxKeyFrameIntervalKey: 60]])
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
             AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000])
        video.expectsMediaDataInRealTime = realtime; audio.expectsMediaDataInRealTime = realtime
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        guard writer.canAdd(video), writer.canAdd(audio) else { throw MovieError.message("无法建立 H.264 / AAC 编码器。") }
        writer.add(video); writer.add(audio)
        guard writer.startWriting() else { throw writer.error ?? MovieError.message("无法创建视频文件。") }
    }
    public func pixelBuffer() throws -> CVPixelBuffer {
        // The pool is allocated only after startSession. A standalone buffer is also valid before that.
        var buffer: CVPixelBuffer?
        let result: CVReturn
        if let pool = adaptor.pixelBufferPool { result = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) }
        else { result = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                    [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer) }
        guard result == kCVReturnSuccess, let buffer else { throw MovieError.message("视频缓冲区分配失败。") }
        return buffer
    }
    @discardableResult public func appendVideo(_ buffer: CVPixelBuffer, at time: CMTime) throws -> Bool {
        guard !finishing else { return false }
        try checkStatus()
        if startTime == nil { writer.startSession(atSourceTime: time); startTime = time }
        guard lastVideo == nil || time > lastVideo! else { return false }
        guard video.isReadyForMoreMediaData else { droppedVideo += 1; return false }
        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw writer.error ?? MovieError.message("写入画面失败。")
        }
        lastVideo = time; endTime = CMTimeAdd(time, CMTime(value: 1, timescale: 30)); videoFrames += 1
        return true
    }
    @discardableResult public func appendAudio(_ sample: CMSampleBuffer) throws -> Bool {
        guard !finishing, let startTime else { return false }
        try checkStatus()
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts >= startTime, lastAudio == nil || pts > lastAudio! else { return false }
        guard audio.isReadyForMoreMediaData else { droppedAudio += 1; return false }
        guard audio.append(sample) else { throw writer.error ?? MovieError.message("写入麦克风声音失败。") }
        lastAudio = pts; audioBuffers += 1
        return true
    }
    public func finish(completion: @escaping (Result<MovieStats, Error>) -> Void) {
        guard !finishing else { completion(.failure(MovieError.message("正在完成文件，请稍候。"))); return }
        finishing = true
        guard let startTime, let endTime, videoFrames > 0 else {
            writer.cancelWriting(); completion(.failure(MovieError.message("没有收到完整屏幕和头像画面，未生成有效录制。"))); return
        }
        writer.endSession(atSourceTime: endTime)
        video.markAsFinished(); audio.markAsFinished()
        let stats = MovieStats(videoFrames: videoFrames, audioBuffers: audioBuffers,
                              droppedVideoFrames: droppedVideo, droppedAudioBuffers: droppedAudio,
                              duration: CMTimeGetSeconds(endTime - startTime))
        writer.finishWriting { [self] in
            if writer.status == .completed { completion(.success(stats)) }
            else { completion(.failure(writer.error ?? MovieError.message("完成视频文件失败。"))) }
        }
    }
    public func cancel() { guard !finishing else { return }; finishing = true; writer.cancelWriting() }
    private func checkStatus() throws {
        guard writer.status == .writing else { throw writer.error ?? MovieError.message("编码器已停止。") }
    }
}
