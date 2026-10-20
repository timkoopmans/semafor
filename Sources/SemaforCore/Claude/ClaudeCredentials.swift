import Foundation
import Security

/// Seam over the Claude Code OAuth token so providers can be tested with fakes.
public protocol ClaudeCredentialReading: Sendable {
    /// - Throws: `ProviderError.auth(.missingCredentials)` when the keychain
    ///   item is absent, `ProviderError.auth(.expiredCredentials)` when it is
    ///   present but unusable.
    func accessToken() throws -> String
}

/// Reads the `Claude Code-credentials` generic-password item that Claude Code
/// maintains in the macOS Keychain (re-read per call; never cached, never
/// logged). First read from a new binary triggers one Keychain approval prompt.
public struct ClaudeKeychainReader: ClaudeCredentialReading {
    private static let service = "Claude Code-credentials"

    public init() {}

    public func accessToken() throws -> String {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw ProviderError.auth(.missingCredentials)
        }

        struct Stored: Decodable {
            struct Oauth: Decodable {
                let accessToken: String
            }
            let claudeAiOauth: Oauth
        }

        guard let stored = try? JSONDecoder().decode(Stored.self, from: data),
              !stored.claudeAiOauth.accessToken.isEmpty
        else {
            throw ProviderError.auth(.expiredCredentials)
        }
        return stored.claudeAiOauth.accessToken
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: NSUserName(),
        ]
    }
}
