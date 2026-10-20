import Foundation

/// ChatGPT OAuth tokens as Codex CLI stores them under `tokens` in auth.json.
public struct CodexTokens: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let accountId: String?

    public init(accessToken: String, refreshToken: String?, accountId: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accountId = accountId
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case accountId = "account_id"
    }
}

/// Seam over `~/.codex/auth.json` for testability.
public protocol CodexAuthReading: Sendable {
    /// - Throws: `ProviderError.auth(.missingCredentials)` when the file or a
    ///   usable access token is absent.
    func tokens() throws -> CodexTokens
}

/// Reads `auth.json` fresh on every call (the CLI refreshes it underneath us);
/// contents are never cached and never logged.
public struct CodexFileReader: CodexAuthReading {
    private let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex"))
    {
        self.home = home
    }

    public func tokens() throws -> CodexTokens {
        struct AuthFile: Decodable {
            let tokens: CodexTokens?
        }

        guard let data = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
              let file = try? JSONDecoder().decode(AuthFile.self, from: data),
              let tokens = file.tokens,
              !tokens.accessToken.isEmpty
        else {
            throw ProviderError.auth(.missingCredentials)
        }
        return tokens
    }
}
