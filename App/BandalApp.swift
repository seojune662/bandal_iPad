import SwiftUI

@main
struct BandalApp: App {
    /// Made once here: SwiftUI re-runs the view's init, and a store made there would be a new one each time.
    /// A profile switch replaces it, which also rebuilds the view.
    @State private var store = NativeWorkspaceStore()
    var body: some Scene {
        WindowGroup {
            NativeWorkspaceView(store: store)
                .id(ObjectIdentifier(store))
                .onReceive(NotificationCenter.default.publisher(for: DesktopProfileService.didActivate)) { _ in store = NativeWorkspaceStore() }
                .statusBarHidden(true)
                .ignoresSafeArea(.container, edges: .top)
                .bandalLocalized()
        }
    }
}

enum BandalTheme {
    static let accent = Color(red: 0.19, green: 0.39, blue: 0.33)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let panel = Color(uiColor: .secondarySystemGroupedBackground)
}
