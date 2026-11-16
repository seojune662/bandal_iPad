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
    /// `image`: a web page's own icon (`NativeTabFavicons`), drawn as it is in place of the symbol.
    func configure(title: String, symbol: String, image: UIImage? = nil, density: NativeDockTabSizing.Density, fontScale: Double, selected: Bool,
                   metrics: NativeDockStripMetrics = .single, dimmed: Bool = false, mutedIcon: Bool = false, closeInside: Bool = false) {
        var configuration = UIButton.Configuration.plain()
        configuration.title = density == .icon ? nil : title
        configuration.image = image.map { mutedIcon ? Self.faded($0) : $0 } ?? UIImage(systemName: symbol)
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
    /// The Figma pill: padding, icon, 6 and the title, then the tab's 44-point ×, which every tab has.
    /// UIKit measures its own configuration, so a hugging tab never truncates its title.
    /// `pageIcon`: the tab may show a web page's 16-point icon, a little wider than the symbols: measure with one.
    static func naturalWidth(title: String, symbol: String, metrics: NativeDockStripMetrics, fontScale: Double, selected: Bool, pageIcon: Bool = false) -> CGFloat {
        measuring.configure(title: title, symbol: symbol, image: pageIcon ? iconSlot : nil, density: .regular, fontScale: fontScale, selected: selected, metrics: metrics, closeInside: true)
        return ceil(measuring.fittingWidth) + NativeDockTabSizing.closeTarget
    }
    private static let iconSlot = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { _ in }
    private static let measuring = NativeDockTabButton(frame: .zero)
    private var fittingWidth: CGFloat { super.intrinsicContentSize.width }
    /// A page icon in a pane that is not being written in, as the symbols there are muted.
    private static func faded(_ image: UIImage) -> UIImage {
        UIGraphicsImageRenderer(size: image.size, format: image.imageRendererFormat).image { _ in image.draw(at: .zero, blendMode: .normal, alpha: 0.55) }
    }
}

/// A dock tab as the strip holds it: the button draws, this view takes the touches. A button (a UIControl) would
/// keep the scrolling strip from moving when a finger slides along it after resting on a tab; a plain view with a
/// tap lets the strip take that slide, and a tap still chooses the tab.
final class NativeDockTabView: UIView {
    let button = NativeDockTabButton(frame: .zero)
    var onTap: () -> Void = {}
    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        button.isUserInteractionEnabled = false
        button.isAccessibilityElement = false
        button.accessibilityElementsHidden = true
        button.translatesAutoresizingMaskIntoConstraints = true
        button.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        button.frame = bounds
        addSubview(button)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isAccessibilityElement = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 44) }
    @objc private func tapped() { onTap() }
    func configure(title: String, symbol: String, image: UIImage?, density: NativeDockTabSizing.Density, fontScale: Double, selected: Bool,
                   metrics: NativeDockStripMetrics, dimmed: Bool, mutedIcon: Bool, closeInside: Bool) {
        button.configure(title: title, symbol: symbol, image: image, density: density, fontScale: fontScale, selected: selected,
                         metrics: metrics, dimmed: dimmed, mutedIcon: mutedIcon, closeInside: closeInside)
        accessibilityLabel = title
        accessibilityTraits = selected ? [.button, .selected] : [.button]
    }
    override func accessibilityActivate() -> Bool { onTap(); return true }
}
