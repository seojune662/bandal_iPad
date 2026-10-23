import SwiftUI
import UIKit

/// Per-provider consent to send user content from this device to the provider's API.
/// Every AI request goes through `DesktopAIService.run`, which asks here first.
enum AIConsent {
    static func isGranted(_ provider: AIProvider) -> Bool { UserDefaults.standard.bool(forKey: key(provider)) }
    static func set(_ provider: AIProvider, granted: Bool) { UserDefaults.standard.set(granted, forKey: key(provider)) }
    private static func key(_ provider: AIProvider) -> String { "ai.consent.\(provider.rawValue)" }

    static func company(_ provider: AIProvider) -> String {
        switch provider { case .openai: "OpenAI"; case .claude: "Anthropic"; case .gemini: "Google" }
    }
    static func policy(_ provider: AIProvider) -> URL {
        switch provider {
        case .openai: URL(string: "https://openai.com/policies/privacy-policy/")!
        case .claude: URL(string: "https://www.anthropic.com/legal/privacy")!
        case .gemini: URL(string: "https://policies.google.com/privacy")!
        }
    }

    /// Shows the consent sheet and stores the answer. Returns false when nothing can present it.
    @MainActor static func ask(_ provider: AIProvider, english: Bool) async -> Bool {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        guard var presenter = scene?.keyWindow?.rootViewController else { return false }
        while let next = presenter.presentedViewController { presenter = next }
        let granted = await withCheckedContinuation { continuation in
            var controller: UIViewController?
            let view = AIConsentView(provider: provider, english: english) { answer in
                controller?.dismiss(animated: true)
                continuation.resume(returning: answer)
            }
            controller = UIHostingController(rootView: view)
            controller?.modalPresentationStyle = .formSheet
            controller?.isModalInPresentation = true
            presenter.present(controller!, animated: true)
        }
        if granted { set(provider, granted: true) }
        return granted
    }
}

private struct AIConsentView: View {
    let provider: AIProvider
    let english: Bool
    let answer: (Bool) -> Void
    @State private var answered = false

    var body: some View {
        let company = AIConsent.company(provider)
        VStack(alignment: .leading, spacing: 16) {
            Text(english ? "Send to \(company)?" : "\(company)에 보낼까요?").font(.title3.weight(.semibold))
            Text(english ? "To answer, the following is sent from this iPad directly to \(company):" : "답변을 받기 위해 다음 내용이 이 iPad에서 \(company)에 바로 전송됩니다.")
            VStack(alignment: .leading, spacing: 6) {
                Label(english ? "Your question and the conversation" : "입력한 질문과 대화 내용", systemImage: "text.bubble")
                Label(english ? "Images you attach" : "첨부한 이미지", systemImage: "photo")
                Label(english ? "Materials, notes or web pages you let the AI read" : "AI가 읽도록 선택한 자료, 노트, 웹페이지 내용", systemImage: "doc.text")
            }.font(.callout)
            Text(english ? "It is sent with your own API key and does not pass through Krunchmallow servers. Krunchmallow does not receive or store it. \(company) handles it under its privacy policy." : "전송에는 직접 등록한 API 키를 사용하며 크런치맬로 서버를 거치지 않습니다. 크런치맬로는 이 내용을 받거나 저장하지 않습니다. 전송된 내용은 \(company)의 개인정보 처리방침에 따라 처리됩니다.")
            Link(english ? "\(company) privacy policy" : "\(company) 개인정보 처리방침", destination: AIConsent.policy(provider))
            Text(english ? "You can withdraw consent anytime in Settings › AI Engine." : "설정 › AI 엔진에서 언제든 동의를 철회할 수 있습니다.").font(.footnote).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(english ? "Cancel" : "취소") { reply(false) }.accessibilityIdentifier("native-ai-consent-cancel")
                Button(english ? "Agree and Send" : "동의하고 보내기") { reply(true) }.buttonStyle(.borderedProminent).accessibilityIdentifier("native-ai-consent-accept")
            }
        }.padding(24).frame(maxWidth: 520).accessibilityElement(children: .contain).accessibilityIdentifier("native-ai-consent")
    }
    private func reply(_ value: Bool) {
        guard !answered else { return }
        answered = true; answer(value)
    }
}
