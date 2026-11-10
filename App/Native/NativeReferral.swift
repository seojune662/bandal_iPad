import Foundation
import Observation

/// A friend's invitation on this iPad, and the signed-in account's own invite status.
/// The invitee's side moves by itself: a code that exists is kept here (`pending`) until someone
/// is signed in, then it is claimed (`awaiting`), and its reward is asked for once there is a course.
@MainActor
@Observable
final class NativeReferral {
    /// What the code field shows under itself.
    enum Entry: Equatable { case idle, checking, applied, invalid, unavailable, refused(ReferralError) }
    /// One line for a toast; `text` puts it in the app's language.
    enum Notice: Equatable {
        /// The reward came in: this many "AI N회".
        case rewarded(uses: Int)
        /// The waiting code can never be claimed by this account.
        case refused(ReferralError)
    }
    static let pendingKey = "native.referral.pending", awaitingKey = "native.referral.awaiting"

    /// The server; the platform services install the signed-in one.
    @ObservationIgnored var service: any ReferralService
    /// A code that exists, kept on this iPad until someone signs in.
    private(set) var pending: String? { didSet { defaults.set(pending, forKey: Self.pendingKey) } }
    /// The account has claimed a code; its reward waits for the first course.
    private(set) var awaiting: Bool { didSet { defaults.set(awaiting, forKey: Self.awaitingKey) } }
    /// `/status` of the signed-in account: nil signed out, and until something asks for it.
    private(set) var status: ReferralStatus?
    var notice: Notice?
    /// The code of an invite link that opened the app; the code field takes it.
    var linkedCode: String?
    /// Someone is signed in, as the account service last said.
    private(set) var signedIn = false
    /// Counts account changes: an answer that began before the latest one belongs to someone else.
    @ObservationIgnored private var session = 0
    /// The latest step (tests wait for it).
    @ObservationIgnored private(set) var work: Task<ReferralError?, Never>?

    private let defaults: UserDefaults
    private let hasCourse: () -> Bool
    private let refreshUsage: () async -> Void

    init(service: any ReferralService, defaults: UserDefaults = .standard, hasCourse: @escaping () -> Bool,
         refreshUsage: @escaping () async -> Void = {}) {
        self.service = service; self.defaults = defaults; self.hasCourse = hasCourse; self.refreshUsage = refreshUsage
        pending = defaults.string(forKey: Self.pendingKey).flatMap { Referral.isCode($0) ? $0 : nil }
        awaiting = defaults.bool(forKey: Self.awaitingKey)
    }

    /// An invitation is under way: the sidebar says what brings the reward.
    var applied: Bool { pending != nil || awaiting }

    /// A complete code from the field: asks whether it exists, keeps it and, signed in, claims it at once.
    func enter(_ code: String) async -> Entry {
        // Only a code is ever kept or sent.
        guard Referral.isCode(code) else { return .invalid }
        do { guard try await service.check(code) else { return .invalid } }
        catch is CancellationError { return .idle }
        catch { return .unavailable }
        guard !Task.isCancelled else { return .idle }
        pending = code
        if let refusal = await advance(announcing: false).value { return .refused(refusal) }
        // An earlier step may have settled this code first; what it had to say is the toast.
        return pending == code || awaiting ? .applied : .idle
    }

    /// An invite link (bandal.io/r/CODE) hands its code to the code field; any other address does nothing.
    func open(_ link: URL) {
        if let code = Referral.code(link: link) { linkedCode = code }
    }

    /// The field no longer shows the waiting code, so it is not kept. A claimed code stays claimed.
    func withdraw() { pending = nil }

    /// Signing in claims a waiting code, once per sign-in: the account service repeats its state
    /// (a new nickname, a restored session). Then, with no invitation under way on this iPad, it
    /// asks what the account itself still has open: a claim belongs to the account, so one made on
    /// another iPad, before a reinstall, or before someone else used this iPad is taken up again.
    /// Signing out takes the account's numbers and its waiting reward off this iPad; the server keeps the claim.
    func accountChanged(signedIn: Bool) {
        guard signedIn != self.signedIn else { return }
        self.signedIn = signedIn; session += 1
        if signedIn { advance(resuming: true) } else { status = nil; awaiting = false }
    }

    /// Asks for this account's invite status. False: nobody is signed in, and nothing was asked.
    func loadStatus() async throws -> Bool {
        let session = session
        guard await service.isSignedIn() else { status = nil; return false }
        let loaded: ReferralStatus
        do { loaded = try await service.status() }
        catch ReferralError.signInRequired { status = nil; return false }
        // The account changed while the server answered: these numbers are not this account's.
        guard session == self.session else { throw CancellationError() }
        status = loaded
        // Claimed on another iPad or before a reinstall: its reward waits for the first course here too.
        if loaded.claim?.completed == false, !awaiting { awaiting = true; advance() }
        return true
    }

    /// Takes the invitation as far as it can go now: called on sign-in, on a new code and when the
    /// first course appears. Steps run one at a time, in the order asked; nothing retries by itself.
    /// A refusal becomes the toast unless the caller shows it (`announcing: false`).
    @discardableResult func advance(announcing: Bool = true, resuming: Bool = false) -> Task<ReferralError?, Never> {
        let previous = work
        let task = Task { () -> ReferralError? in
            _ = await previous?.value
            let refusal = await self.step()
            if announcing, let refusal { self.notice = .refused(refusal) }
            // A sign-in that left nothing under way here: does the account have a claim still open?
            if resuming, !self.applied { _ = try? await self.loadStatus() }
            return refusal
        }
        work = task
        return task
    }

    /// Returns why the waiting code was refused, if it was.
    private func step() async -> ReferralError? {
        guard applied, await service.isSignedIn() else { return nil }
        if let code = pending {
            // A code typed while the server answers stays for the next step: only this one is settled here.
            do { try await service.claim(code) }
            catch let error as ReferralError where [.invalidCode, .ownCode, .alreadyClaimed].contains(error) { if pending == code { pending = nil }; return error }
            catch { return nil } // No connection, or signed out meanwhile: the code waits for the next sign-in.
            if pending == code { pending = nil }
            awaiting = true
        }
        // Not before there is a course. When the server cannot answer, the next sign-in, launch or first course asks again.
        guard awaiting, hasCourse(), let outcome = try? await service.complete() else { return nil }
        awaiting = false
        if case .rewarded(let credit) = outcome {
            notice = .rewarded(uses: Referral.uses(credit))
            await refreshUsage()
        }
        // The numbers already on screen follow.
        if status != nil, let fresh = try? await service.status() { status = fresh }
        return nil
    }
}

extension NativeReferral.Notice {
    func text(_ locale: Locale) -> String {
        switch self {
        case .rewarded(let uses): String(format: NativeAppLocale.string("AI %lld회가 들어왔어요", locale), uses)
        case .refused(.ownCode): NativeAppLocale.string("내 초대 코드는 내가 쓸 수 없어요.", locale)
        case .refused(.alreadyClaimed): NativeAppLocale.string("이미 다른 초대 코드를 썼어요.", locale)
        case .refused: NativeAppLocale.string("없는 초대 코드예요.", locale)
        }
    }
}
