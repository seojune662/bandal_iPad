import UIKit
import SwiftMath

/// SwiftMath uses native font metrics and CoreGraphics for TeX typesetting.
/// The attachment never replaces the original formula in the Markdown model.
@MainActor
enum NativeRichTextMath {
    private static let cache = NSCache<NSString, UIImage>()
    static func image(_ formula: String, size: CGFloat, color: UIColor, traits: UITraitCollection = .current) -> UIImage {
        let color = color.resolvedColor(with: traits)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let key = "\(size):\(red):\(green):\(blue):\(alpha):\(formula)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let label = MTMathUILabel()
        label.fontSize = size; label.textColor = color; label.labelMode = .display
        label.displayErrorInline = false; label.latex = formula.utf16.count <= 8_192 ? formula : ""
        // 1.7.3 exposes intrinsicContentSize (UIView.sizeThatFits is not
        // overridden), and its image API supplies the CoreText Y-axis transform.
        let measured = label.intrinsicContentSize
        let valid = label.error == nil && measured.width.isFinite && measured.height.isFinite && measured.width > 0 && measured.height > 0 && measured.width <= 1_600 && measured.height <= 700 && formula.utf16.count <= 8_192
        let rendered = valid ? MTMathImage(latex: formula, fontSize: size, textColor: color).asImage().1 : nil
        let bounds = rendered?.size ?? CGSize(width: 360, height: 56)
        let image = UIGraphicsImageRenderer(size: CGSize(width: bounds.width + 16, height: bounds.height + 12)).image { _ in
            if let rendered { rendered.draw(at: CGPoint(x: 8, y: 6)) }
            else { ("수식: " + formula as NSString).draw(in: CGRect(x: 8, y: 6, width: bounds.width, height: bounds.height), withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 15, weight: .regular), .foregroundColor: color]) }
        }
        cache.countLimit = 128; cache.totalCostLimit = 24 * 1024 * 1024
        cache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        return image
    }
}
