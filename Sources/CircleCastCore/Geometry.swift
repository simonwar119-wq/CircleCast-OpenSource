import Foundation
import CoreGraphics

/// All geometry is in AppKit's global, bottom-left coordinate space.
/// Normalization removes each display's origin (including negative origins).
public enum OverlayGeometry {
    public static func clamp(_ rect: CGRect, to display: CGRect) -> CGRect {
        let side = min(max(96, rect.width), min(480, min(display.width, display.height)))
        return CGRect(x: min(max(rect.minX, display.minX), display.maxX - side),
                      y: min(max(rect.minY, display.minY), display.maxY - side),
                      width: side, height: side)
    }
    public static func normalized(_ rect: CGRect, in display: CGRect) -> CGRect {
        let r = clamp(rect, to: display)
        return CGRect(x: (r.minX - display.minX) / display.width,
                      y: (r.minY - display.minY) / display.height,
                      width: r.width / display.width, height: r.height / display.height)
    }
    public static func pixels(_ normalized: CGRect, width: Int, height: Int) -> CGRect {
        let side = min(normalized.width * CGFloat(width), normalized.height * CGFloat(height))
        return CGRect(x: normalized.minX * CGFloat(width), y: normalized.minY * CGFloat(height), width: side, height: side)
    }
    public static func outputSize(for display: CGSize, longestEdge: CGFloat = 1920) -> (Int, Int) {
        let scale = min(1, longestEdge / max(display.width, display.height))
        return (max(2, Int(display.width * scale) / 2 * 2), max(2, Int(display.height * scale) / 2 * 2))
    }
}

/// Only this value crosses the UI/render queues; it never contains prompt text.
public final class OverlayState: @unchecked Sendable {
    private let lock = NSLock()
    private var rect = CGRect(x: 0.8, y: 0.12, width: 0.15, height: 0.25)
    public init() {}
    public func set(_ newValue: CGRect) { lock.lock(); rect = newValue; lock.unlock() }
    public func get() -> CGRect { lock.lock(); defer { lock.unlock() }; return rect }
}

public enum RecorderPhase: String {
    case idle, requesting, countdown, preparing, recording, stopping
}

/// A small transition gate prevents overlapping start/stop operations.
public struct RecordingLifecycle {
    public private(set) var phase: RecorderPhase = .idle
    public init() {}
    @discardableResult public mutating func begin() -> Bool {
        guard phase == .idle else { return false }; phase = .requesting; return true
    }
    public mutating func advance(_ next: RecorderPhase) {
        let valid: Bool
        switch (phase, next) {
        case (.requesting, .countdown), (.countdown, .preparing), (.preparing, .recording),
             (.requesting, .stopping), (.countdown, .stopping), (.preparing, .stopping),
             (.recording, .stopping), (.stopping, .idle): valid = true
        default: valid = false
        }
        precondition(valid, "Invalid recording lifecycle transition: \(phase) -> \(next)")
        phase = next
    }
}
