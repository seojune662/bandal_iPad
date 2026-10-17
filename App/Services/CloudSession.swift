import Foundation

struct CloudSession: Codable {
    var access_token: String
    var refresh_token: String
    var expires_at: Double?
    var user: CloudUser
}
struct CloudUser: Codable { var id: String; var email: String? }

