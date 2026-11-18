import Foundation

struct CloudSession: Codable {
    var access_token: String
    var refresh_token: String
    var expires_at: Double?
    var user: CloudUser
}
struct CloudUser: Codable {
    var id: String; var email: String?
    /// How the account signed in ("apple", "google"), as the auth server reports it;
    /// `providers` lists every sign-in linked to it.
    var app_metadata: Metadata?
    struct Metadata: Codable { var provider: String?; var providers: [String]? }
}

