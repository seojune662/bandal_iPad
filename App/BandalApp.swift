import SwiftUI

@main
struct BandalApp: App {
    @State private var profileGeneration = UUID()
    var body: some Scene {
        WindowGroup {
            NativeWorkspaceView()
                .id(profileGeneration)
                .onReceive(NotificationCenter.default.publisher(for: DesktopProfileService.didActivate)) { _ in profileGeneration = UUID() }
                .statusBarHidden(true)
                .ignoresSafeArea(.container, edges: .top)
        }
    }
}

enum BandalTheme {
    static let accent = Color(red: 0.19, green: 0.39, blue: 0.33)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let panel = Color(uiColor: .secondarySystemGroupedBackground)
}
