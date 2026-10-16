import XCTest
import AppKit
@testable import CircleCast

/// Instantiates app-owned windows without ordering them onto the user's desktop.
/// Does not create AVCaptureSession, SCStream, or request any permissions.
final class WindowTests: XCTestCase {
    @MainActor func testControlWindowFitsWithoutShowingOrStartingCapture() throws {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let window = delegate.buildWindow()
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let stack = try XCTUnwrap(content.subviews.first as? NSStackView)
        for view in stack.arrangedSubviews {
            let frame = view.convert(view.bounds, to: content)
            XCTAssertTrue(content.bounds.insetBy(dx: -1, dy: -1).contains(frame), "Control clipped: \(frame)")
        }
        XCTAssertFalse(window.isVisible)
        window.close()
        withExtendedLifetime(delegate) {}
    }

    @MainActor func testCameraWindowDragResizeAndNormalizationWithoutDevices() throws {
        _ = NSApplication.shared
        let saved = UserDefaults.standard.object(forKey: "cameraFrame")
        defer { if let saved { UserDefaults.standard.set(saved, forKey: "cameraFrame") } else { UserDefaults.standard.removeObject(forKey: "cameraFrame") } }
        let camera = CameraPanel()
        var geometry = CGRect.zero
        camera.onGeometry = { geometry = $0 }
        let display = CGRect(x: -1920, y: 180, width: 1920, height: 1080)
        camera.place(on: display)
        camera.updateFrame(CGRect(x: -1400, y: 400, width: 180, height: 180))
        XCTAssertEqual(camera.frame.origin, CGPoint(x: -1400, y: 400))
        XCTAssertEqual(geometry.minX, 520.0 / 1920, accuracy: 0.001)
        camera.resize(to: 260)
        XCTAssertEqual(camera.frame.width, 260)
        for corner in 0..<4 {
            camera.corner(corner)
            XCTAssertTrue(display.contains(camera.frame))
            XCTAssertEqual(camera.frame.width, 260)
        }
        camera.updateFrame(CGRect(x: 20000, y: -5000, width: 900, height: 900))
        XCTAssertTrue(display.contains(camera.frame))
        XCTAssertEqual(camera.frame.width, 480)
        camera.attach(nil)
        XCTAssertFalse(camera.isVisible)
        camera.close()
    }
    @MainActor func testPromptCanResizeAndRecoverAfterDisplayRemoval() throws {
        _ = NSApplication.shared
        let keys = ["promptFrame", "promptText", "promptFont", "promptSpeed"]
        let saved = Dictionary(uniqueKeysWithValues: keys.map { ($0, UserDefaults.standard.object(forKey: $0)) })
        defer {
            for key in keys {
                if let value = saved[key] ?? nil { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        let panel = PromptPanel()
        XCTAssertTrue(panel.styleMask.contains(.resizable)); XCTAssertTrue(panel.canBecomeKey)
        let current = try XCTUnwrap(NSScreen.screens.first?.visibleFrame)
        panel.setFrame(CGRect(x: -90000, y: -90000, width: 2000, height: 2500), display: false)
        panel.recoverToVisibleScreen(preferred: current)
        XCTAssertTrue(NSScreen.screens.contains { $0.visibleFrame.contains(panel.frame) })
        panel.setContentSize(CGSize(width: 480, height: 280))
        panel.textView.string = "这是一段本地测试文稿。\n第二行。"
        panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(panel.textView.enclosingScrollView?.frame.width ?? 0, 100)
        XCTAssertGreaterThan(panel.textView.enclosingScrollView?.frame.height ?? 0, 80)
        panel.pause(); XCTAssertFalse(panel.isVisible)
        panel.close()
    }
}
