import AuthenticationServices
import UIKit

struct DesktopAppleCredential { let identityToken: String; let authorizationCode: String? }

/// Apple credentials remain in the native host and are exchanged with Supabase.
@MainActor
final class DesktopAppleAuthorization: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<DesktopAppleCredential, Error>?
    private var controller: ASAuthorizationController?

    func authorize(hashedNonce: String) async throws -> DesktopAppleCredential {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard self.continuation == nil else { continuation.resume(throwing: DesktopRuntimeError("로그인을 진행 중입니다.")); return }
                self.continuation = continuation
                let request = ASAuthorizationAppleIDProvider().createRequest()
                request.requestedScopes = [.fullName, .email]
                request.nonce = hashedNonce
                let controller = ASAuthorizationController(authorizationRequests: [request])
                self.controller = controller; controller.delegate = self; controller.presentationContextProvider = self
                controller.performRequests()
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }
    func cancel() { controller?.cancel(); finish(.failure(CancellationError())) }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard controller === self.controller, let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let data = credential.identityToken, let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            finish(.failure(DesktopRuntimeError("Apple 로그인 응답을 확인하지 못했습니다."))); return
        }
        finish(.success(DesktopAppleCredential(identityToken: token, authorizationCode: credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) })))
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        guard controller === self.controller else { return }; finish(.failure(error))
    }
    private func finish(_ result: Result<DesktopAppleCredential, Error>) {
        let pending = continuation; continuation = nil; controller = nil; pending?.resume(with: result)
    }
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
