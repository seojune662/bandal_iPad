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

    /// `dimmed`: a split pane's tab that is not the selected tab of the pane being written in (Figma 130:5933).
    /// `closeInside`: the pill's × follows the title, so the button ends without trailing padding.
    func configure(title: String, symbol: String, density: NativeDockTabSizing.Density, fontScale: Double, selected: Bool,
                   metrics: NativeDockStripMetrics = .single, dimmed: Bool = false, mutedIcon: Bool = false, closeInside: Bool = false) {
        var configuration = UIButton.Configuration.plain()
        configuration.title = density == .icon ? nil : title
        configuration.image = UIImage(systemName: symbol)
        configuration.imagePadding = density == .icon ? 0 : 6
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: metrics.icon, weight: .regular, scale: .medium)
        let edge = density == .icon ? 4 : metrics.tabPadding
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: edge, bottom: 0, trailing: closeInside ? 0 : edge)
        let titleColor = UIColor(selected && !dimmed ? NativeDesktopTheme.text : NativeDesktopTheme.secondary)
        let iconColor = mutedIcon ? UIColor(NativeDesktopTheme.muted) : titleColor
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var next = attributes; next.font = .systemFont(ofSize: metrics.title * fontScale, weight: selected ? .semibold : .regular); next.foregroundColor = titleColor; return next
        }
        configuration.imageColorTransformer = UIConfigurationColorTransformer { _ in iconColor }
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.baseForegroundColor = titleColor
        self.configuration = configuration
        contentHorizontalAlignment = density == .icon ? .center : .leading
        titleLabel?.numberOfLines = 1
        titleLabel?.lineBreakMode = .byTruncatingTail
        titleLabel?.clipsToBounds = true
        accessibilityLabel = title
        accessibilityTraits = selected ? [.button, .selected] : [.button]
    }
    /// The Figma pill: padding, icon, 6, title and, on the selected tab, 6 and the ×.
    /// UIKit measures its own configuration, so a hugging tab never truncates its title.
    static func naturalWidth(title: String, symbol: String, metrics: NativeDockStripMetrics, fontScale: Double, selected: Bool) -> CGFloat {
        measuring.configure(title: title, symbol: symbol, density: .regular, fontScale: fontScale, selected: selected, metrics: metrics, closeInside: selected)
        return ceil(measuring.fittingWidth) + (selected ? metrics.closeZone : 0)
    }
    private static let measuring = NativeDockTabButton(frame: .zero)
    private var fittingWidth: CGFloat { super.intrinsicContentSize.width }
}
