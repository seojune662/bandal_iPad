import Foundation
import SwiftUI
import UIKit

/// A captured value, never a live reference: editing the source cannot change a sent question.
struct NativeAssistantAttachment: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let text: String?
    let imageDataURL: String?
    let courseID: String?
    let relativePath: String?
    let page: Int?
    let url: String?
    let capturedAt: Date
    let revision: String?

    init(id: String = UUID().uuidString, title: String, text: String? = nil, imageDataURL: String? = nil,
         courseID: String? = nil, relativePath: String? = nil, page: Int? = nil, url: String? = nil,
         capturedAt: Date = Date(), revision: String? = nil) {
        self.id = id; self.title = title; self.text = text; self.imageDataURL = imageDataURL
        self.courseID = courseID; self.relativePath = relativePath; self.page = page; self.url = url
        self.capturedAt = capturedAt; self.revision = revision
    }
    static func dataURL(_ image: UIImage) -> String? {
        image.pngData().map { "data:image/png;base64," + $0.base64EncodedString() }
    }
}

@MainActor
final class NativeAnnotationCoordinator: ObservableObject {
    struct Request: Identifiable, Equatable {
        let id: String
        let documentID: String
        let spaceID: String
    }
    struct Capture: Identifiable, Equatable {
        let id: String
        let spaceID: String
        let attachment: NativeAssistantAttachment
    }
    @Published private(set) var request: Request?
    @Published private(set) var completed: Capture?
    @Published private(set) var error: String?
    @Published var regionMode = true
    func begin(documentID: String, spaceID: String) {
        if request != nil { cancel() }
        error = nil; regionMode = true
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        request = Request(id: UUID().uuidString, documentID: documentID, spaceID: spaceID)
    }
    func cancel() { request = nil; error = nil }
    func consumeCompleted() { completed = nil }
    func complete(_ attachment: NativeAssistantAttachment, requestID: String) {
        guard let request, request.id == requestID else { return }
        completed = Capture(id: requestID, spaceID: request.spaceID, attachment: attachment)
        self.request = nil; error = nil
    }
    func fail(_ message: String, requestID: String) {
        guard request?.id == requestID else { return }; error = message
    }
}

/// Captures only the selected editor's view; never the app window or other panes.
@MainActor
final class NativeAnnotationViewCapture: ObservableObject {
    weak var view: UIView?
    func image(normalized bounds: CGRect) -> UIImage? {
        guard let view, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let crop = CGRect(x: view.bounds.minX + bounds.minX * view.bounds.width,
                          y: view.bounds.minY + bounds.minY * view.bounds.height,
                          width: bounds.width * view.bounds.width, height: bounds.height * view.bounds.height).intersection(view.bounds)
        guard crop.width > 1, crop.height > 1 else { return nil }
        let format = UIGraphicsImageRendererFormat(); format.opaque = true
        format.scale = min(2, 2048 / max(crop.width, crop.height), sqrt(4_000_000 / (crop.width * crop.height)))
        return UIGraphicsImageRenderer(size: crop.size, format: format).image { renderer in
            UIColor.systemBackground.setFill(); renderer.fill(CGRect(origin: .zero, size: crop.size))
            renderer.cgContext.translateBy(x: -crop.minX, y: -crop.minY)
            view.layer.render(in: renderer.cgContext)
        }
    }
}

/// A transparent selection surface is present only in explicit region mode.
struct NativeAnnotationRegionOverlay: View {
    let selected: (CGRect) -> Void
    var tapped: ((CGPoint) -> Void)? = nil
    @State private var start: CGPoint?
    @State private var end: CGPoint?
    @State private var dragSize: CGSize?
    @State private var geometryChanged = false
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.accentColor.opacity(0.035)
                if let start, let end {
                    Rectangle().fill(Color.accentColor.opacity(0.12))
                        .overlay(Rectangle().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 3])))
                        .frame(width: abs(end.x - start.x), height: abs(end.y - start.y))
                        .offset(x: min(start.x, end.x), y: min(start.y, end.y))
                }
            }.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    if dragSize == nil { dragSize = geometry.size }
                    start = value.startLocation; end = value.location
                }.onEnded { value in
                    defer { start = nil; end = nil; dragSize = nil; geometryChanged = false }
                    guard !geometryChanged, dragSize == geometry.size, geometry.size.width > 0, geometry.size.height > 0 else { return }
                    if hypot(value.translation.width, value.translation.height) < 8 {
                        tapped?(CGPoint(x: value.location.x / geometry.size.width, y: value.location.y / geometry.size.height)); return
                    }
                    let box = CGRect(x: min(value.startLocation.x, value.location.x) / geometry.size.width,
                                     y: min(value.startLocation.y, value.location.y) / geometry.size.height,
                                     width: abs(value.translation.width) / geometry.size.width,
                                     height: abs(value.translation.height) / geometry.size.height)
                        .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                    if box.width > 0, box.height > 0 { selected(box) }
                })
                .onChange(of: geometry.size) { _, _ in
                    if dragSize != nil { geometryChanged = true; start = nil; end = nil }
                }
        }.accessibilityElement(children: .ignore)
            .accessibilityIdentifier("native-ai-annotation-region")
            .accessibilityLabel("질문할 영역을 드래그하세요")
    }
}

struct NativeAnnotationToolbar: View {
    @ObservedObject var coordinator: NativeAnnotationCoordinator
    @Binding var regionMode: Bool
    var supportsElement = false
    var busy = false
    let attachText: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("지목 방식", selection: $regionMode) {
                    Text("텍스트").tag(false)
                    Text(supportsElement ? "영역·요소" : "영역").tag(true)
                }.pickerStyle(.segmented).frame(maxWidth: 260)
                Spacer(minLength: 0)
                if busy { ProgressView() }
                if !regionMode {
                    Button(action: attachText) { Text("선택 첨부").frame(minHeight: 44).contentShape(Rectangle()) }
                        .accessibilityIdentifier("native-ai-annotation-attach-text")
                }
                Button { coordinator.cancel() } label: {
                    Text("취소").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }.accessibilityIdentifier("native-ai-annotation-cancel")
            }
            Text(coordinator.error ?? (regionMode ? "질문할 부분을 드래그하세요" : "텍스트를 선택한 뒤 ‘선택 첨부’를 누르세요"))
                .font(.caption).foregroundStyle(coordinator.error == nil ? Color.secondary : Color.red)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8)
        }.padding(.horizontal, 12).background(.regularMaterial)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("native-ai-annotation-toolbar")
    }
}

/// Each page owns its capture view, so a paged note cannot capture a neighbouring page.
struct NativeAnnotatableTextEditor: View {
    var editor: NativeRichTextEditor
    let document: NativeDocumentReference
    let page: Int?
    let editorAccessibilityID: String
    @ObservedObject var coordinator: NativeAnnotationCoordinator
    @StateObject private var capture = NativeAnnotationViewCapture()
    private var request: NativeAnnotationCoordinator.Request? {
        coordinator.request?.documentID == document.id ? coordinator.request : nil
    }
    var body: some View {
        var editor = editor
        editor.editorAccessibilityID = editorAccessibilityID
        editor.captureViewChanged = { [capture] in capture.view = $0 }
        editor.selectionOnly = request != nil
        return editor.overlay {
            if let request, coordinator.regionMode {
                NativeAnnotationRegionOverlay { bounds in
                    guard let image = capture.image(normalized: bounds), let dataURL = NativeAssistantAttachment.dataURL(image) else {
                        coordinator.fail("선택한 노트 영역을 캡처하지 못했습니다.", requestID: request.id); return
                    }
                    coordinator.complete(.init(title: document.title, imageDataURL: dataURL, courseID: document.courseID,
                        relativePath: document.relativePath, page: page, revision: UUID().uuidString), requestID: request.id)
                }
            }
        }.accessibilityElement(children: .contain)
    }
}
