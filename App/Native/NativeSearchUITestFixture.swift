#if DEBUG
import UIKit

/// Seeds a course with something of every searchable kind: a text PDF, a Markdown note, a note with
/// (synthetic) pen strokes that the real recogniser then reads, and a conversation. Kept behind the
/// isolated UI-test root and its own launch argument.
@MainActor
enum NativeSearchUITestFixture {
    static var requested: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--native-ui-testing") && arguments.contains("--native-search-fixture")
    }
    private static var seeded = Set<String>()

    static func seedIfRequested(store: NativeWorkspaceStore, courseID: String?) async {
        guard requested, let courseID, store.root.lastPathComponent.hasPrefix("BandalDesktop-Native-UI-Tests"), seeded.insert(courseID).inserted else { return }
        do {
            let page = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
            let lecture = UIGraphicsPDFRenderer(bounds: page).pdfData { renderer in
                for (index, lines) in [["열역학 제2법칙", "고립계의 엔트로피는 감소하지 않는다.", "Entropy of an isolated system never decreases."],
                                       ["카르노 순환", "두 등온 과정과 두 단열 과정으로 이루어진다.", "효율은 1 - Tc/Th 이다."],
                                       ["엔트로피 변화 계산", "가역 과정에서 dS = dQ/T.", "엔트로피는 상태 함수이므로 경로와 무관하다."]].enumerated() {
                    renderer.beginPage()
                    UIColor.white.setFill(); UIRectFill(page)
                    for (row, line) in lines.enumerated() {
                        (line as NSString).draw(at: CGPoint(x: 60, y: 90 + CGFloat(row) * (row == 0 ? 0 : 44) + (row > 0 ? 30 : 0)),
                                                withAttributes: [.font: UIFont.systemFont(ofSize: row == 0 ? 30 : 18, weight: row == 0 ? .semibold : .regular), .foregroundColor: UIColor.black])
                    }
                    ("\(index + 1)" as NSString).draw(at: CGPoint(x: 290, y: 800), withAttributes: [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.gray])
                }
            }
            _ = try await store.invoke("materials:writeFile", ["courseId": courseID, "dirRelPath": "", "fileName": "열역학 강의자료.pdf", "encoding": "base64", "data": lecture.base64EncodedString()])
            _ = try await store.invoke("materials:writeFile", ["courseId": courseID, "dirRelPath": "", "fileName": "2주차 정리.md", "encoding": "utf8",
                "data": "# 2주차 정리\n\n엔트로피는 무질서도의 척도다. 볼츠만 식 S = k ln W.\n\n다음 시간: 카르노 순환과 열기관 효율.\n"])
            let note = try await store.invoke("pdfNotes:create", ["courseId": courseID, "title": "필기 노트", "paper": "blank", "orientation": "portrait"]) as? [String: Any]
            if let path = note?["relPath"] as? String {
                let revision = try await store.invokePrivate("nativePDF:binding", ["courseId": courseID, "relPath": path]) as? [String: Any]
                _ = try await store.invoke("pdf:restructure", ["courseId": courseID, "relPath": path, "expectedRevision": revision?["documentRevision"] ?? "",
                                                               "operationId": UUID().uuidString, "pages": [["source": 1], ["source": NSNull()]]])
                let written: [(Int, CGFloat, String, String)] = [(1, 150, "엔트로피 증가 법칙", "ink"), (1, 250, "Carnot cycle", "blue"), (1, 350, "dS = dQ / T", "ink"),
                                                                 (2, 180, "엔트로피 복습 문제", "ink"), (2, 280, "heat engine", "red")]
                for (number, y, text, color) in written {
                    for stroke in NativeHandwritingFixture.strokes(text, at: CGPoint(x: 70, y: y), fontSize: 46, pageSize: page.size, color: color) {
                        _ = try await store.invoke("drawings:create", stroke.merging(["courseId": courseID, "relPath": path, "page": number, "kind": "ink"]) { _, new in new })
                    }
                }
            }
            for (question, answer) in [("엔트로피가 왜 항상 증가해?", "고립계에서는 가능한 미시 상태의 수가 많은 쪽으로 진행하기 때문에 엔트로피가 증가합니다."),
                                       ("카르노 순환 효율 공식 알려줘", "카르노 효율은 1 - Tc/Th 입니다. 엔트로피 변화가 0인 가역 순환입니다.")] {
                let identity: [String: Any] = ["courseId": courseID, "sessionId": UUID().uuidString, "surface": "app"]
                _ = try await store.invokePrivate("nativeChat:open", identity)
                _ = try await store.invokePrivate("nativeChat:begin", identity.merging(["content": question]) { _, new in new })
                _ = try await store.invokePrivate("nativeChat:finish", identity.merging(["turnSeq": 1, "text": answer]) { _, new in new })
            }
            await store.refreshMaterials()
        } catch { store.errorMessage = "search fixture: " + error.localizedDescription }
    }
}
#endif
