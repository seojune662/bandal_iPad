import SwiftUI

@main
struct BandalApp: App {
    var body: some Scene {
        WindowGroup {
            DesktopShell()
                .statusBarHidden(true)
        }
    }
}

enum BandalTheme {
    static let accent = Color(red: 0.19, green: 0.39, blue: 0.33)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let panel = Color(uiColor: .secondarySystemGroupedBackground)
}
