import SwiftUI
import UIKit
import CryptoKit

private struct NativeWorkspaceChromeModeKey: EnvironmentKey { static let defaultValue = NativeWorkspaceChromeMode.all }
private struct NativeWorkspaceControlInsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private struct NativeWorkspaceTopInsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private struct NativeWorkspacePreviewControllerKey: EnvironmentKey { static let defaultValue: NativeWorkspacePreviewController? = nil }
extension EnvironmentValues {
    var nativeWorkspaceChromeMode: NativeWorkspaceChromeMode {
        get { self[NativeWorkspaceChromeModeKey.self] }
        set { self[NativeWorkspaceChromeModeKey.self] = newValue }
    }
    var nativeWorkspaceControlInset: CGFloat {
        get { self[NativeWorkspaceControlInsetKey.self] }
        set { self[NativeWorkspaceControlInsetKey.self] = newValue }
    }
    var nativeWorkspaceTopInset: CGFloat {
        get { self[NativeWorkspaceTopInsetKey.self] }
        set { self[NativeWorkspaceTopInsetKey.self] = newValue }
    }
    var nativeWorkspacePreviewController: NativeWorkspacePreviewController? {
        get { self[NativeWorkspacePreviewControllerKey.self] }
        set { self[NativeWorkspacePreviewControllerKey.self] = newValue }
    }
}

/// Captures one dock rectangle. Native GPU/web content supplies its own pixels;
/// neither a second editor nor a second website is mounted for a preview.
@MainActor
final class NativeWorkspacePreviewController: ObservableObject {
    typealias Capture = @MainActor () async throws -> UIImage?
    @Published private(set) var revision = 0
    weak var anchor: UIView?
    var capturesAnchorContents = false
    private struct Surface {
        weak var view: UIView?
        let id: String
        let privateContent: () -> Bool
        let capture: Capture?
        let excluded: Bool
        let occludesContent: Bool
    }
    private var surfaces: [UUID: Surface] = [:]
    private var generation = UUID()
    private let images = NSCache<NSString, UIImage>()
    init() { images.totalCostLimit = 24 * 1024 * 1024; images.countLimit = 24 }

    func invalidate() { generation = UUID() }
    func register(_ token: UUID, view: UIView, id: String, privateContent: @escaping () -> Bool,
                  capture: Capture?, excluded: Bool = false, occludesContent: Bool = false) {
        surfaces[token] = Surface(view: view, id: id, privateContent: privateContent, capture: capture,
                                  excluded: excluded, occludesContent: occludesContent)
    }
    func unregister(_ token: UUID) { surfaces.removeValue(forKey: token) }

    static func fileURL(root: URL, workspaceID: String, windowID: String) -> URL {
        let digest = SHA256.hash(data: Data((workspaceID + "\u{0}" + windowID).utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("NativeWorkspacePreviews", isDirectory: true).appendingPathComponent(digest + ".jpg")
    }
    func image(root: URL, workspaceID: String, windowID: String) -> UIImage? {
        let url = Self.fileURL(root: root, workspaceID: workspaceID, windowID: windowID), key = url.path as NSString
        if let image = images.object(forKey: key) { return image }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        remember(image, key: key); return image
    }
    func remove(root: URL, workspaceID: String, windowID: String) throws {
        invalidate()
        let url = Self.fileURL(root: root, workspaceID: workspaceID, windowID: windowID)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        images.removeObject(forKey: url.path as NSString); revision += 1
    }
    private func remember(_ image: UIImage, key: NSString) {
        images.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
    }
    private static func visible(_ view: UIView, in window: UIWindow) -> Bool {
        var current: UIView? = view
        while let node = current {
            if node.isHidden || node.alpha < 0.01 { return false }
            if node === window { return true }
            current = node.superview
        }
        return false
    }
    private static func hasPresentation(_ controller: UIViewController?) -> Bool {
        guard let controller else { return false }
        return controller.presentedViewController != nil || controller.children.contains { hasPresentation($0) }
    }
    private final class Completion {
        var continuation: CheckedContinuation<Bool, Never>?
        var deadline: Task<Void, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func finish(_ value: Bool) {
            guard let continuation else { return }
            self.continuation = nil; deadline?.cancel(); deadline = nil
            continuation.resume(returning: value)
        }
    }
    @discardableResult
    func capture(root: URL, workspaceID: String, windowID: String) async -> Bool {
        invalidate(); let request = generation
        return await withCheckedContinuation { continuation in
            let completion = Completion(continuation)
            let operation = Task { @MainActor in
                completion.finish(await self.captureCurrent(root: root, workspaceID: workspaceID, windowID: windowID, request: request))
            }
            completion.deadline = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                if self.generation == request { self.invalidate() }
                operation.cancel(); completion.finish(false)
            }
        }
    }
    private func captureCurrent(root: URL, workspaceID: String, windowID: String, request: UUID) async -> Bool {
        guard request == generation else { return false }
        guard let anchor, let window = anchor.window, Self.visible(anchor, in: window) else { return false }
        // A presented tab list, form or system sheet is not workspace content
        // and may include private tab metadata outside the registered panes.
        guard !Self.hasPresentation(window.rootViewController) else { return false }
        let isolated = capturesAnchorContents
        let dock = anchor.convert(anchor.bounds, to: window)
        guard dock.width > 1, dock.height > 1, window.bounds.contains(dock) else { return false }
        func visibleEntries() -> [(UUID, Surface, CGRect)] {
            surfaces.compactMap { token, value -> (UUID, Surface, CGRect)? in
                guard let view = value.view, Self.visible(view, in: window) else { return nil }
                if isolated && !view.isDescendant(of: anchor) { return nil }
                let frame = view.convert(view.bounds, to: window)
                return frame.intersects(dock) && frame.width > 1 && frame.height > 1 ? (token, value, frame) : nil
            }
        }
        let entries = visibleEntries()
        // A drawer must stay open. Never cache its pixels as document content.
        guard !entries.contains(where: { $0.1.occludesContent }) else { return false }
        let privacy = Dictionary(uniqueKeysWithValues: entries.map { ($0.0, $0.1.privateContent()) })
        func unchanged() -> Bool {
            guard generation == request, self.anchor === anchor, anchor.window === window, capturesAnchorContents == isolated,
                  anchor.convert(anchor.bounds, to: window) == dock,
                  !Self.hasPresentation(window.rootViewController),
                  Set(visibleEntries().map(\.0)) == Set(entries.map(\.0)) else { return false }
            return entries.allSatisfy { token, value, frame in
                guard let registered = surfaces[token], let view = value.view,
                      registered.view === view, registered.id == value.id, Self.visible(view, in: window),
                      view.convert(view.bounds, to: window) == frame else { return false }
                return registered.privateContent() == privacy[token]
            }
        }
        do {
            var captured: [(CGRect, UIImage)] = []
            for (token, value, frame) in entries where !value.excluded && value.capture != nil {
                // Private pages are not passed to WKWebView.takeSnapshot at all.
                guard privacy[token] != true else { continue }
                guard let image = try await value.capture?(), unchanged() else { return false }
                captured.append((frame, image))
            }
            guard unchanged(), !Task.isCancelled else { return false }
            let format = UIGraphicsImageRendererFormat(); format.opaque = true
            format.scale = min(1, 1200 / max(dock.width, dock.height))
            // Opaque covers are inserted and removed in this synchronous turn,
            // before another display commit, so protected pixels never enter the
            // UIKit snapshot and the user never sees a flashing mask.
            let covers = entries.filter { privacy[$0.0] == true || $0.1.capture != nil || $0.1.excluded }.map { _, _, frame -> UIView in
                let cover = UIView(frame: isolated ? anchor.convert(frame, from: window) : frame)
                cover.backgroundColor = .secondarySystemBackground
                cover.isUserInteractionEnabled = false; (isolated ? anchor : window).addSubview(cover); return cover
            }
            defer { covers.forEach { $0.removeFromSuperview() } }
            let result = UIGraphicsImageRenderer(size: dock.size, format: format).image { renderer in
                UIColor.secondarySystemBackground.setFill(); renderer.fill(CGRect(origin: .zero, size: dock.size))
                if isolated {
                    anchor.layer.render(in: renderer.cgContext)
                    renderer.cgContext.translateBy(x: -dock.minX, y: -dock.minY)
                } else {
                    renderer.cgContext.translateBy(x: -dock.minX, y: -dock.minY)
                    window.layer.render(in: renderer.cgContext)
                }
                for (frame, image) in captured { image.draw(in: frame) }
                for (token, value, frame) in entries where privacy[token] == true || value.excluded {
                    UIColor.secondarySystemBackground.setFill(); renderer.cgContext.fill(frame)
                    if privacy[token] == true {
                        let label = "개인정보 보호"
                        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 14), .foregroundColor: UIColor.secondaryLabel]
                        let size = label.size(withAttributes: attributes)
                        label.draw(at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2), withAttributes: attributes)
                    }
                }
            }
            guard unchanged(), let bytes = result.jpegData(compressionQuality: 0.78) else { return false }
            let url = Self.fileURL(root: root, workspaceID: workspaceID, windowID: windowID)
            var directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true; try directory.setResourceValues(values)
            try bytes.write(to: url, options: .atomic)
            remember(result, key: url.path as NSString); revision += 1; return true
        } catch { return false }
    }
}

struct NativeWorkspacePreviewAnchor: UIViewRepresentable {
    let controller: NativeWorkspacePreviewController
    func makeUIView(context: Context) -> UIView { let view = UIView(); view.isUserInteractionEnabled = false; controller.anchor = view; controller.capturesAnchorContents = false; return view }
    func updateUIView(_ view: UIView, context: Context) { controller.anchor = view; controller.capturesAnchorContents = false }
}

/// The central dock has one persistent UIKit host. Capturing that host excludes
/// sibling drawers, fixed controls and the system keyboard without changing any
/// of their visible state. Updating rootView retains the same SwiftUI identities.
struct NativeWorkspacePreviewContainer<Content: View>: UIViewControllerRepresentable {
    @Environment(\.self) private var environment
    let controller: NativeWorkspacePreviewController
    let content: Content
    let isInteractive: Bool
    init(controller: NativeWorkspacePreviewController, isInteractive: Bool = true, @ViewBuilder content: () -> Content) {
        self.controller = controller; self.isInteractive = isInteractive; self.content = content()
    }
    struct Root: View {
        let content: Content
        let values: EnvironmentValues
        var body: some View { content.environment(\.self, values) }
    }
    final class Host: UIViewController {
        let hosting: UIHostingController<Root>
        init(root: Root) {
            hosting = UIHostingController(rootView: root); hosting.safeAreaRegions = []
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidLoad() {
            super.viewDidLoad(); view.backgroundColor = .clear
            addChild(hosting); view.addSubview(hosting.view)
            hosting.view.backgroundColor = .clear; hosting.view.frame = view.bounds
            hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            hosting.didMove(toParent: self)
        }
    }
    func makeUIViewController(context: Context) -> Host {
        let host = Host(root: Root(content: content, values: environment)); host.loadViewIfNeeded()
        applyVisibility(host)
        controller.anchor = host.hosting.view; controller.capturesAnchorContents = true
        return host
    }
    func updateUIViewController(_ host: Host, context: Context) {
        host.hosting.rootView = Root(content: content, values: environment)
        applyVisibility(host)
        controller.anchor = host.hosting.view; controller.capturesAnchorContents = true
    }
    private func applyVisibility(_ host: Host) {
        // SwiftUI hiding does not reliably cross a nested hosting controller's
        // accessibility boundary. Block the actual UIKit subtree as well.
        host.hosting.view.isUserInteractionEnabled = isInteractive
        host.hosting.view.accessibilityElementsHidden = !isInteractive
        host.hosting.view.isHidden = !isInteractive
    }

}

private struct NativeWorkspacePreviewSurface: UIViewRepresentable {
    let controller: NativeWorkspacePreviewController?
    let id: String
    let privateContent: () -> Bool
    let capture: NativeWorkspacePreviewController.Capture?
    let excluded: Bool
    let occludesContent: Bool
    let enabled: Bool
    final class Coordinator { let token = UUID(); weak var controller: NativeWorkspacePreviewController? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIView { let view = UIView(); view.isUserInteractionEnabled = false; return view }
    func updateUIView(_ view: UIView, context: Context) {
        if context.coordinator.controller !== controller { context.coordinator.controller?.unregister(context.coordinator.token) }
        context.coordinator.controller = controller
        guard enabled else { controller?.unregister(context.coordinator.token); return }
        controller?.register(context.coordinator.token, view: view, id: id, privateContent: privateContent,
                             capture: capture, excluded: excluded, occludesContent: occludesContent)
    }
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) { coordinator.controller?.unregister(coordinator.token) }
}
private struct NativeWorkspacePreviewModifier: ViewModifier {
    @Environment(\.nativeWorkspacePreviewController) private var controller
    @Environment(\.nativeEditorVisible) private var editorVisible
    let id: String
    let privateContent: () -> Bool
    let capture: NativeWorkspacePreviewController.Capture?
    let excluded: Bool
    let occludesContent: Bool
    let enabled: Bool
    func body(content: Content) -> some View {
        content.background(NativeWorkspacePreviewSurface(controller: controller, id: id, privateContent: privateContent,
                                                          capture: capture, excluded: excluded, occludesContent: occludesContent, enabled: enabled && editorVisible))
    }
}
extension View {
    func nativeWorkspacePreviewSurface(id: String, privateContent: @escaping () -> Bool = { false },
                                       capture: NativeWorkspacePreviewController.Capture? = nil) -> some View {
        modifier(NativeWorkspacePreviewModifier(id: id, privateContent: privateContent, capture: capture, excluded: false, occludesContent: false, enabled: true))
    }
    func nativeWorkspacePreviewExcluded(occludesContent: Bool = false, enabled: Bool = true) -> some View {
        modifier(NativeWorkspacePreviewModifier(id: "excluded", privateContent: { false }, capture: nil, excluded: true, occludesContent: occludesContent, enabled: enabled))
    }
}
