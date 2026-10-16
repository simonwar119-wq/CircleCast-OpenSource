import Foundation
import CoreImage
import CoreVideo

public final class CircleCompositor {
    public let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    public init(software: Bool = false) {
        context = CIContext(options: [.useSoftwareRenderer: software, .cacheIntermediates: false,
                                      .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    }
    private func fit(_ image: CIImage, into rect: CGRect) -> CIImage {
        let extent = image.extent
        let scale = max(rect.width / extent.width, rect.height / extent.height)
        let normalized = image.transformed(by: .init(translationX: -extent.minX, y: -extent.minY))
        return normalized.transformed(by: .init(scaleX: scale, y: scale))
            .transformed(by: .init(translationX: rect.midX - extent.width * scale / 2,
                                  y: rect.midY - extent.height * scale / 2)).cropped(to: rect)
    }
    private func mask(_ rect: CGRect, bounds: CGRect) -> CIImage {
        let radius = rect.width / 2
        return CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: rect.midX, y: rect.midY),
            "inputRadius0": max(0, radius - 0.8), "inputRadius1": radius + 0.2,
            "inputColor0": CIColor.white, "inputColor1": CIColor.black
        ])!.outputImage!.cropped(to: bounds)
    }
    /// Composes actual pixels. The UI preview and teleprompter are never inputs.
    public func image(screen: CIImage, camera: CIImage, normalizedRect: CGRect,
                      width: Int, height: Int, mirror: Bool = true) -> CIImage {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let circle = OverlayGeometry.pixels(normalizedRect, width: width, height: height)
        var face = camera
        if mirror {
            face = camera.transformed(by: .init(a: -1, b: 0, c: 0, d: 1, tx: camera.extent.minX + camera.extent.maxX, ty: 0))
        }
        let base = fit(screen, into: bounds)
        let border = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: bounds)
        let outlined = border.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: base, kCIInputMaskImageKey: mask(circle, bounds: bounds)])
        let inner = circle.insetBy(dx: 2, dy: 2)
        return fit(face, into: circle).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: outlined, kCIInputMaskImageKey: mask(inner, bounds: bounds)]).cropped(to: bounds)
    }
    public func render(screen: CVPixelBuffer, camera: CVPixelBuffer, normalizedRect: CGRect,
                       into output: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(output), height = CVPixelBufferGetHeight(output)
        let result = image(screen: CIImage(cvPixelBuffer: screen), camera: CIImage(cvPixelBuffer: camera),
                           normalizedRect: normalizedRect, width: width, height: height)
        context.render(result, to: output, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: colorSpace)
    }
}
