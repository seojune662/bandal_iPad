import UIKit

/// UIKit's intrinsic UIButton width must not override a compressed SwiftUI tab.
final class NativeDockTabButton: UIButton {
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 44) }
    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel?.numberOfLines = 1
        titleLabel?.lineBreakMode = .byTruncatingTail
        titleLabel?.clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, symbol: String, density: NativeDockTabSizing.Density, fontScale: Double, selected: Bool) {
        var configuration = UIButton.Configuration.plain()
        configuration.title = density == .icon ? nil : title
        configuration.image = UIImage(systemName: symbol)
        configuration.imagePadding = density == .icon ? 0 : 6
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 12)
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: density == .icon ? 4 : 8, bottom: 0, trailing: density == .regular ? 2 : 8)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var next = attributes; next.font = UIFont.systemFont(ofSize: 13 * fontScale, weight: selected ? .medium : .regular); return next
        }
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.baseForegroundColor = UIColor(selected ? NativeDesktopTheme.text : NativeDesktopTheme.muted)
        self.configuration = configuration
        contentHorizontalAlignment = density == .icon ? .center : .leading
        titleLabel?.numberOfLines = 1
        titleLabel?.lineBreakMode = .byTruncatingTail
        titleLabel?.clipsToBounds = true
        accessibilityLabel = title
        accessibilityTraits = selected ? [.button, .selected] : [.button]
    }
}
