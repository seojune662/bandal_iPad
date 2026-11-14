import Foundation

extension NativeAssistantSession {
    /// UI tests have no signed-in AI. With `--native-ai-stream-fixture` (Debug only) the panel's first conversation
    /// plays one answer in slowly, a paragraph at a time, so a test can switch 사이드바 ↔ 플로팅 while it streams and see it carry on.
    /// It runs in the panel's own task: a panel rebuilt by the switch would cut it off.
    func playStreamFixture() async {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--native-ai-stream-fixture") else { return }
        while !ready { guard !Task.isCancelled else { return }; try? await Task.sleep(for: .milliseconds(100)) }
        guard messages.isEmpty, !running, !sending else { return }
        let answer = (1...16).map { "\($0). 인터뷰 다섯 명 가운데 네 명이 첫 화면이 복잡하다고 답했고, 다음 주에는 팔레트 시안 두 가지를 나란히 비교합니다." }
            .joined(separator: "\n\n")
        do {
            _ = try await store.invokePrivate("nativeChat:begin", identity.merging(["content": "이 노트 핵심만 요약해 줘"]) { _, new in new })
            try await open()
        } catch { return }
        running = true; stream = ""
        // A paragraph at a time with a pause after it: XCUITest waits for the app to go idle before each query.
        for paragraph in answer.components(separatedBy: "\n\n") {
            for word in paragraph.split(separator: " ") {
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled else { return }
                stream += (stream.isEmpty || stream.hasSuffix("\n\n") ? "" : " ") + word
            }
            stream += "\n\n"
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
        }
        _ = try? await store.invokePrivate("nativeChat:finish", ["courseId": context.courseID, "sessionId": sessionID, "turnSeq": 1, "text": answer])
        running = false
        try? await open()
        #endif
    }
}
