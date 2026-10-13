import SwiftUI

@main
struct BandalApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            WorkspaceView().environmentObject(model)
                .tint(BandalTheme.accent)
                .onOpenURL { if $0.isFileURL { model.importURL($0) } else { model.openLink($0) } }
        }
    }
}

enum BandalTheme {
    static let accent = Color(red: 0.19, green: 0.39, blue: 0.33)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let panel = Color(uiColor: .secondarySystemGroupedBackground)
}
