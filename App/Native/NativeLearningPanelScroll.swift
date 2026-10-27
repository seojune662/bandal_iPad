import SwiftUI
import UIKit

struct NativeLearningPanelScrollState: Codable, Equatable { var offset: Double }

/// Peer content refreshes keep the same ScrollView and never copy a peer's
/// scroll or focus. Only this pane writes its own local restoration position.
private struct NativeLearningPanelScroll: ViewModifier {
    let model: NativeLearningWorkspaceModel
    let detail: String
    @Environment(\.nativeEditorVisible) private var visible
    @State private var position = ScrollPosition(edge: .top)
    @State private var offset = 0.0
    @State private var restored = false
    @State private var saving: Task<Void, Never>?
    private var key: String { model.panelID + ":" + detail }
    func body(content: Content) -> some View {
        content.scrollPosition($position)
            .onScrollGeometryChange(for: Double.self) { Double(max(0, $0.contentOffset.y + $0.contentInsets.top)) } action: { _, value in
                guard visible, restored else { return }
                offset = value
                saving?.cancel()
                saving = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }; save()
                }
            }
            .onAppear { restore() }
            .onChange(of: detail) { old, _ in save(detail: old); restore() }
            .onChange(of: visible) { _, value in if !value { save() } }
            .onDisappear { saving?.cancel(); save() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in save() }
    }
    private func restore() {
        saving?.cancel(); restored = false
        if let state = model.store.panelViewStates.read(NativeLearningPanelScrollState.self, id: key, kind: "learning"), state.offset.isFinite, state.offset >= 0 {
            offset = state.offset; position.scrollTo(y: CGFloat(state.offset))
        } else { offset = 0; position.scrollTo(y: 0) }
        restored = true
    }
    private func save(detail: String? = nil) {
        guard restored else { return }
        do { try model.store.panelViewStates.write(NativeLearningPanelScrollState(offset: offset), id: detail.map { model.panelID + ":" + $0 } ?? key, kind: "learning") }
        catch { model.store.errorMessage = error.localizedDescription }
    }
}

extension View {
    func nativeLearningPanelScroll(model: NativeLearningWorkspaceModel, detail: String) -> some View { modifier(NativeLearningPanelScroll(model: model, detail: detail)) }
}
