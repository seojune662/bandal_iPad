import SwiftUI

/// The app's own language, chosen in onboarding or 설정 › 일반 › 언어. `locale` in settings.json
/// is the preference; `native.locale` is its synchronous rendering cache, like `native.appearance`.
enum NativeAppLocale {
    static let key = "native.locale"
    static let korean = "ko-KR", english = "en-US"
    static func normalize(_ value: Any?) -> String { value as? String == english ? english : korean }
    static var current: String { normalize(UserDefaults.standard.string(forKey: key)) }
    /// Korean on a Korean iPad, English on any other.
    static func device(_ preferred: [String] = Locale.preferredLanguages) -> String {
        preferred.first?.hasPrefix("ko") == true ? korean : english
    }

    private static let englishStrings = Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:))
    /// A Korean UI literal in `locale`'s language, for the places that take a `String` (shared
    /// components, error text). `Text("…")` literals resolve the same table on their own.
    static func string(_ korean: String, _ locale: Locale) -> String {
        guard locale.language.languageCode?.identifier == "en" else { return korean }
        return englishStrings?.localizedString(forKey: korean, value: korean, table: nil) ?? korean
    }
}

extension View {
    /// Puts this hierarchy in the app's language: `Text("…")` literals under it resolve through
    /// Localizable.strings, keyed by the Korean literal. The root and each separately hosted
    /// SwiftUI tree (a UIHostingController does not inherit the root's environment) apply it.
    func bandalLocalized() -> some View { modifier(BandalLocalized()) }
}

private struct BandalLocalized: ViewModifier {
    @AppStorage(NativeAppLocale.key) private var identifier = NativeAppLocale.korean
    func body(content: Content) -> some View {
        content.environment(\.locale, Locale(identifier: NativeAppLocale.normalize(identifier)))
    }
}
