import AuthenticationServices
import UIKit

@MainActor
final class OAuthSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    func open(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            session = ASWebAuthenticationSession(url: url, callbackURLScheme: "bandal") { [weak self] url, error in
                Task { @MainActor in
                    self?.session = nil
                    if let error { continuation.resume(throwing: error) }
                    else if let url { continuation.resume(returning: url) }
                    else { continuation.resume(throwing: AIError.message("로그인 응답을 확인할 수 없습니다.")) }
                }
            }
            session?.presentationContextProvider = self
            if session?.start() != true { session = nil; continuation.resume(throwing: AIError.message("로그인 창을 열 수 없습니다.")) }
        }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
