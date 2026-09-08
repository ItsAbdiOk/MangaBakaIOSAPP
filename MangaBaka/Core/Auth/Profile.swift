import Foundation

/// The signed-in reader, used to confirm a token actually works.
struct Profile: Decodable, Sendable, Equatable {
    let id: String
    let nickname: String?
    let preferredUsername: String?
    /// user, developer, contributor, moderator, admin
    let role: String?
    /// "oauth" or "pat" — worth showing, since the two behave differently.
    let authType: String?

    /// Something to show the reader. Falls back through the names the API may
    /// or may not supply rather than assuming any one of them exists.
    var displayName: String {
        preferredUsername ?? nickname ?? "your account"
    }
}
