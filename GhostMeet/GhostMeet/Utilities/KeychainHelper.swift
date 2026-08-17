//
//  KeychainHelper.swift
//  GhostMeet
//

import Foundation
import Security

/// Storage for a single kind of value: provider API keys.
///
/// The protocol exists for one reason — tests and previews must never touch the
/// real keychain, and nothing else in the app may grow a second way of holding
/// a secret.
///
/// Implementations must never log, print, or otherwise copy a secret anywhere
/// but their own backing store.
nonisolated protocol SecretStore: Sendable {
    /// Returns the stored secret, or `nil` when nothing is stored for `account`.
    func secret(forAccount account: String) throws -> String?

    /// Stores `secret`, or removes the entry when `secret` is `nil` or empty.
    func setSecret(_ secret: String?, forAccount account: String) throws
}

/// Failures the keychain can report. Deliberately carries only the `OSStatus` —
/// never the secret, never the account value — so that an error printed into a
/// log leaks nothing.
nonisolated enum SecretStoreError: Error, Equatable {
    /// The keychain refused the operation.
    case unexpectedStatus(OSStatus)
    /// The stored blob is not valid UTF-8 text.
    case malformedData
}

extension SecretStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? String(localized: "код \(status)")
            return String(localized: "Keychain отказал: \(detail)")
        case .malformedData:
            return String(localized: "Запись в Keychain повреждена.")
        }
    }
}

/// The real keychain, backed by a generic-password item per account.
///
/// Note on the item class: the app is ad-hoc signed and unsandboxed, so this
/// deliberately uses the file-based keychain (no `kSecUseDataProtectionKeychain`),
/// which does not require an application-identifier entitlement.
nonisolated final class KeychainHelper: SecretStore {

    static let shared = KeychainHelper()

    private let service: String

    init(service: String = "\(Bundle.main.bundleIdentifier ?? "Mixxy.GhostMeet").secrets") {
        self.service = service
    }

    func secret(forAccount account: String) throws -> String? {
        var query = baseQuery(forAccount: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let secret = String(data: data, encoding: .utf8) else {
                throw SecretStoreError.malformedData
            }
            return secret
        case errSecItemNotFound:
            return nil
        default:
            throw SecretStoreError.unexpectedStatus(status)
        }
    }

    func setSecret(_ secret: String?, forAccount account: String) throws {
        let query = baseQuery(forAccount: account)

        guard let secret, !secret.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SecretStoreError.unexpectedStatus(status)
            }
            return
        }

        let data = Data(secret.utf8)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            insert[kSecValueData as String] = data
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SecretStoreError.unexpectedStatus(addStatus)
            }
        default:
            throw SecretStoreError.unexpectedStatus(updateStatus)
        }
    }

    private func baseQuery(forAccount account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

/// A `SecretStore` that keeps secrets in memory only. For SwiftUI previews and
/// tests, so neither ever writes into the user's real keychain.
nonisolated final class InMemorySecretStore: SecretStore, @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [String: String]

    init(storage: [String: String] = [:]) {
        self.storage = storage
    }

    func secret(forAccount account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[account]
    }

    func setSecret(_ secret: String?, forAccount account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let secret, !secret.isEmpty {
            storage[account] = secret
        } else {
            storage.removeValue(forKey: account)
        }
    }

    /// Test/preview affordance: what is actually held, without going through
    /// the protocol.
    var contents: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
