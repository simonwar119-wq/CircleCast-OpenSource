import XCTest
import AVFoundation
import CoreImage
@testable import CircleCastCore

final class GeometryTests: XCTestCase {
    func testDisplayOriginsAndCorners() {
        for origin in [CGPoint.zero, CGPoint(x: -1920, y: -300), CGPoint(x: 1440, y: 900)] {
            let screen = CGRect(origin: origin, size: CGSize(width: 1920, height: 1080))
            for point in [CGPoint(x: -10000, y: -10000), CGPoint(x: 10000, y: 10000), origin] {
                let rect = OverlayGeometry.clamp(CGRect(origin: point, size: CGSize(width: 200, height: 200)), to: screen)
                XCTAssertTrue(screen.contains(rect))
                let normalized = OverlayGeometry.normalized(rect, in: screen)
                let pixels = OverlayGeometry.pixels(normalized, width: 1920, height: 1080)
                XCTAssertEqual(pixels.minX, rect.minX - origin.x, accuracy: 0.001)
                XCTAssertEqual(pixels.minY, rect.minY - origin.y, accuracy: 0.001)
                XCTAssertEqual(pixels.width, 200, accuracy: 0.001)
            }
        }
    }
    func testSizeLimitsAndPortrait() {
        let display = CGRect(x: 0, y: 0, width: 1080, height: 1920)
        XCTAssertEqual(OverlayGeometry.clamp(CGRect(x: 0, y: 0, width: 10, height: 10), to: display).width, 96)
        XCTAssertEqual(OverlayGeometry.clamp(CGRect(x: 0, y: 0, width: 9999, height: 9999), to: display).width, 480)
        let landscape = OverlayGeometry.outputSize(for: CGSize(width: 3024, height: 1964))
        XCTAssertEqual(landscape.0, 1920); XCTAssertEqual(landscape.1 % 2, 0)
        let portrait = OverlayGeometry.outputSize(for: display.size)
        XCTAssertEqual(portrait.0, 1080); XCTAssertEqual(portrait.1, 1920)
    }
    func testRepeatedStartStopAndCancelGate() {
        var state = RecordingLifecycle()
        for _ in 0..<100 {
            XCTAssertTrue(state.begin()); XCTAssertFalse(state.begin())
            state.advance(.countdown); state.advance(.preparing); state.advance(.recording)
            XCTAssertFalse(state.begin()); state.advance(.stopping); XCTAssertFalse(state.begin())
            state.advance(.idle)
        }
        for stopAt in [RecorderPhase.requesting, .countdown, .preparing] {
            XCTAssertTrue(state.begin())
            if stopAt != .requesting { state.advance(.countdown) }
            if stopAt == .preparing { state.advance(.preparing) }
            state.advance(.stopping); state.advance(.idle)
            XCTAssertEqual(state.phase, .idle)
        }
    }
}

final class MediaTests: XCTestCase {
    let width = 640, height = 360
    var outputFolder: URL {
        if let path = ProcessInfo.processInfo.environment["CIRCLECAST_TEST_OUTPUT"] { return URL(fileURLWithPath: path) }
        return FileManager.default.temporaryDirectory.appendingPathComponent("CircleCastTests-\(ProcessInfo.processInfo.processIdentifier)")
    }
    func testMP4AndMOVHaveMovingCircularAvatarAndAudibleTrack() async throws {
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        for ext in ["mp4", "mov"] {
            let url = outputFolder.appendingPathComponent("synthetic-circle-and-tone.\(ext)")
            try? FileManager.default.removeItem(at: url)
            let stats = try await makeMovie(url: url)
            XCTAssertEqual(stats.videoFrames, 60); XCTAssertEqual(stats.audioBuffers, 60)
            XCTAssertEqual(stats.droppedVideoFrames, 0); XCTAssertEqual(stats.droppedAudioBuffers, 0)
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            XCTAssertEqual(CMTimeGetSeconds(duration), 2, accuracy: 0.1)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertEqual(videoTracks.count, 1); XCTAssertEqual(audioTracks.count, 1)
            let videoTrack = try XCTUnwrap(videoTracks.first)
            let naturalSize = try await videoTrack.load(.naturalSize)
            XCTAssertEqual(naturalSize, CGSize(width: width, height: height))
            let reader = try AVAssetReader(asset: asset)
            let video = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(video); XCTAssertTrue(reader.startReading())
            var count = 0
            while let sample = video.copyNextSampleBuffer() {
                let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
                if count == 10 {
                    // Small avatar: center red, bounding-square corner remains blue (a real circle).
                    assertColor(buffer, x: 104, yFromBottom: 104, red: true)
                    assertColor(buffer, x: 48, yFromBottom: 48, red: false)
                    assertColor(buffer, x: 420, yFromBottom: 160, red: false)
                    if ext == "mp4" { try savePNG(buffer, name: "decoded-small-circle.png") }
                }
                if count == 45 {
                    assertColor(buffer, x: 490, yFromBottom: 214, red: true)
                    assertColor(buffer, x: 104, yFromBottom: 104, red: false)
                    assertColor(buffer, x: 407, yFromBottom: 131, red: false)
                    if ext == "mp4" { try savePNG(buffer, name: "decoded-moved-large-circle.png") }
                }
                count += 1
            }
            XCTAssertEqual(reader.status, .completed); XCTAssertEqual(count, 60)
            let audioReader = try AVAssetReader(asset: asset)
            let audio = AVAssetReaderTrackOutput(track: try XCTUnwrap(audioTracks.first), outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
            audioReader.add(audio); XCTAssertTrue(audioReader.startReading())
            var squared = 0.0, samples = 0, crossings = 0, previous: Float = 0
            while let sample = audio.copyNextSampleBuffer() {
                let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
                let length = CMBlockBufferGetDataLength(block)
                var floats = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
                let status = floats.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
                XCTAssertEqual(status, noErr)
                for value in floats {
                    squared += Double(value * value); samples += 1
                    if previous < 0 && value >= 0 { crossings += 1 }; previous = value
                }
            }
            XCTAssertEqual(audioReader.status, .completed)
            let rms = sqrt(squared / Double(samples)), seconds = Double(samples) / 48000
            XCTAssertGreaterThan(samples, 90000); XCTAssertGreaterThan(rms, 0.15); XCTAssertLessThan(rms, 0.3)
            XCTAssertEqual(Double(crossings) / seconds, 440, accuracy: 8)
            print("VERIFIED \(url.path): video=\(count) frames; audio=\(samples) decoded PCM samples; RMS=\(rms); frequency≈\(Double(crossings)/seconds)Hz")
        }
    }
    func testWriterRepeatedRunsAndEmptyCancellation() async throws {
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        for index in 0..<3 {
            let url = outputFolder.appendingPathComponent("repeat-\(index).mp4"); try? FileManager.default.removeItem(at: url)
            weak var released: MovieWriter?
            do {
                let writer = try MovieWriter(url: url, width: width, height: height, realtime: false)
                released = writer
                let buffer = try writer.pixelBuffer()
                let compositor = CircleCompositor()
                compositor.context.render(CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: width, height: height)), to: buffer)
                for frame in 0..<3 {
                    try waitReady { writer.videoReady }
                    try writer.appendVideo(buffer, at: CMTime(value: Int64(frame), timescale: 30))
                    try waitReady { writer.audioReady }
                    try writer.appendAudio(audioSample(frame: frame))
                }
                let stats = try await finish(writer)
                XCTAssertEqual(stats.videoFrames, 3)
                // Late callbacks after finish must be ignored, never touch a closed writer.
                XCTAssertFalse(try writer.appendVideo(buffer, at: CMTime(value: 4, timescale: 30)))
            }
            XCTAssertNil(released)
            try FileManager.default.removeItem(at: url)
        }
        let emptyURL = outputFolder.appendingPathComponent("empty.mp4"); try? FileManager.default.removeItem(at: emptyURL)
        let empty = try MovieWriter(url: emptyURL, width: width, height: height)
        do { _ = try await finish(empty); XCTFail("Empty take must fail") } catch { XCTAssertEqual(empty.writer.status, .cancelled) }
        try? FileManager.default.removeItem(at: emptyURL)
    }
    private func makeMovie(url: URL) async throws -> MovieStats {
        let writer = try MovieWriter(url: url, width: width, height: height, realtime: true)
        let compositor = CircleCompositor()
        let screen = CIImage(color: CIColor(red: 0.05, green: 0.2, blue: 0.8)).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let camera = CIImage(color: CIColor(red: 0.9, green: 0.1, blue: 0.05)).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 90))
        for frame in 0..<60 {
            // Same stationary screen/camera input; layout changes halfway through the final video.
            let rect = frame < 30 ? CGRect(x: 40.0/640, y: 40.0/360, width: 128.0/640, height: 128.0/360)
                                 : CGRect(x: 400.0/640, y: 124.0/360, width: 180.0/640, height: 180.0/360)
            let buffer = try writer.pixelBuffer()
            let image = compositor.image(screen: screen, camera: camera, normalizedRect: rect, width: width, height: height)
            compositor.context.render(image, to: buffer)
            if frame > 0 { try waitReady("video frame \(frame)") { writer.videoReady } }
            XCTAssertTrue(try writer.appendVideo(buffer, at: CMTime(value: Int64(frame), timescale: 30)))
            try waitReady("audio frame \(frame)") { writer.audioReady }
            XCTAssertTrue(try writer.appendAudio(audioSample(frame: frame)))
            try await Task.sleep(nanoseconds: 33_333_333)
        }
        return try await finish(writer)
    }
    private func finish(_ writer: MovieWriter) async throws -> MovieStats {
        try await withCheckedThrowingContinuation { continuation in writer.finish { continuation.resume(with: $0) } }
    }
    private func waitReady(_ context: String = "writer", _ ready: () -> Bool) throws {
        let limit = Date().addingTimeInterval(10)
        while !ready() {
            if Date() > limit { throw MovieError.message("Encoder readiness timeout: \(context)") }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }
    private func audioSample(frame: Int) throws -> CMSampleBuffer {
        let count = 1600
        var values = [Int16](repeating: 0, count: count)
        for i in 0..<count { values[i] = Int16(sin(Double(frame * count + i) * 2 * .pi * 440 / 48000) * 0.3 * 32767) }
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count * 2,
                       blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: count * 2, flags: 0, blockBufferOut: &block), noErr)
        let data = try XCTUnwrap(block)
        let copied = values.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: data, offsetIntoDestination: 0, dataLength: count * 2) }
        XCTAssertEqual(copied, noErr)
        var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: CMTime(value: Int64(frame * count), timescale: 48000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        var sampleSize = 2
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: nil, dataBuffer: data, formatDescription: format,
            sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
    private func assertColor(_ buffer: CVPixelBuffer, x: Int, yFromBottom: Int, red: Bool, file: StaticString = #filePath, line: UInt = #line) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let index = (height - 1 - yFromBottom) * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        let b = Int(base[index]), r = Int(base[index + 2])
        if red { XCTAssertGreaterThan(r, b + 100, file: file, line: line) }
        else { XCTAssertGreaterThan(b, r + 100, file: file, line: line) }
    }
    private func savePNG(_ buffer: CVPixelBuffer, name: String) throws {
        try CIContext().writePNGRepresentation(of: CIImage(cvPixelBuffer: buffer), to: outputFolder.appendingPathComponent(name),
                                               format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
}
