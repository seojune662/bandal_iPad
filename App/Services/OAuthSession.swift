import AuthenticationServices
import UIKit

@MainActor
final class OAuthSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var identifier: UUID?
    func open(_ url: URL, callbackScheme: String = "bandal", onStarted: @escaping @MainActor () -> Void = {}) async throws -> URL {
        let identifier = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard self.continuation == nil else { continuation.resume(throwing: AIError.message("이미 로그인 창을 열고 있습니다.")); return }
                self.continuation = continuation
                self.identifier = identifier
                session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] url, error in
                    Task { @MainActor in self?.finish(identifier: identifier, url: url, error: error) }
                }
                session?.presentationContextProvider = self
                if session?.start() == true { onStarted() }
                else { finish(identifier: identifier, url: nil, error: AIError.message("로그인 창을 열 수 없습니다.")) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel(identifier: identifier) } }
    }
    func cancel() {
        guard let identifier else { return }
        cancel(identifier: identifier)
    }
    private func cancel(identifier: UUID) {
        guard self.identifier == identifier else { return }
        session?.cancel()
        finish(identifier: identifier, url: nil, error: CancellationError())
    }
    private func finish(identifier: UUID, url: URL?, error: Error?) {
        guard self.identifier == identifier, let continuation else { return }
        self.continuation = nil; self.identifier = nil; session = nil
        if let error { continuation.resume(throwing: error) }
        else if let url { continuation.resume(returning: url) }
        else { continuation.resume(throwing: AIError.message("로그인 응답을 확인할 수 없습니다.")) }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
