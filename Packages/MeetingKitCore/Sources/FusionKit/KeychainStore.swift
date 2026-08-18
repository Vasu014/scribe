import Foundation
import Security

/// Typed Keychain failures. No force-unwraps anywhere in this file; every
/// Security-framework status is checked and surfaced.
public enum KeychainStoreError: Error, Equatable, Sendable {
    /// A Security call returned a status other than the expected one(s).
    case unexpectedStatus(status: OSStatus, operation: String)
    /// The stored item's data was not the expected type.
    case unexpectedResult
    /// The stored item's data was not valid UTF-8.
    case invalidUTF8
}

/// Minimal wrapper over the Security framework for ONE generic-password item
/// holding the Anthropic API key (SPEC §4.5: per-user key in Keychain,
/// entered in Settings). Public so the App target can use it directly for the
/// masked key field in Settings (SPEC §5).
///
/// Uses `kSecUseDataProtectionKeychain` so the item behaves correctly with
/// the app's (future) entitlements on modern macOS.
///
/// Service name uses the PLACEHOLDER bundle id `com.example.scribe` (SPEC
/// §3.1) — must be finalized before signing week, together with the real
/// bundle id.
public final class KeychainStore: Sendable {

    /// Placeholder bundle id (SPEC §3.1) — update when the bundle id is finalized.
    public static let defaultService = "com.example.scribe"
    /// Keychain account for the Anthropic API key item.
    public static let anthropicAPIKeyAccount = "anthropic-api-key"

    private let service: String
    private let account: String

    /// Creates a store for a single generic-password item.
    public init(
        service: String = KeychainStore.defaultService,
        account: String = KeychainStore.anthropicAPIKeyAccount
    ) {
        self.service = service
        self.account = account
    }

    // MARK: API

    /// Saves (inserts or updates) the API key item.
    public func saveAPIKey(_ apiKey: String) throws {
        let data = Data(apiKey.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]

        let copyStatus = SecItemCopyMatching(baseQuery() as CFDictionary, nil)
        switch copyStatus {
        case errSecSuccess:
            let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainStoreError.unexpectedStatus(status: updateStatus, operation: "SecItemUpdate")
            }
        case errSecItemNotFound:
            var addQuery = baseQuery()
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                // Lost a race between copy and add — fall back to update.
                let retryStatus = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
                guard retryStatus == errSecSuccess else {
                    throw KeychainStoreError.unexpectedStatus(status: retryStatus, operation: "SecItemUpdate (after duplicate)")
                }
            } else {
                guard addStatus == errSecSuccess else {
                    throw KeychainStoreError.unexpectedStatus(status: addStatus, operation: "SecItemAdd")
                }
            }
        default:
            throw KeychainStoreError.unexpectedStatus(status: copyStatus, operation: "SecItemCopyMatching")
        }
    }

    /// Loads the API key, or `nil` when no item exists yet.
    public func loadAPIKey() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status: status, operation: "SecItemCopyMatching")
        }
        guard let data = result as? Data else {
            throw KeychainStoreError.unexpectedResult
        }
        guard let key = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.invalidUTF8
        }
        return key
    }

    /// Deletes the API key item. Idempotent — deleting a missing item is not
    /// an error (matches the Settings "remove key" affordance).
    public func deleteAPIKey() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status: status, operation: "SecItemDelete")
        }
    }

    // MARK: Query construction

    /// Shared search dictionary — service + account + data-protection keychain.
    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
