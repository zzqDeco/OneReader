import Foundation
import Security

protocol ProviderSecretStore: Sendable {
    func save(secret: String, reference: String?) async throws -> String
    func secret(for reference: String) async throws -> String?
    func delete(reference: String) async throws
}

enum ProviderSecretStoreError: LocalizedError, Equatable {
    case keychain(OSStatus)
    case invalidEncoding

    var errorDescription: String? {
        switch self {
        case let .keychain(status): "Keychain 操作失败（\(status)）。"
        case .invalidEncoding: "Keychain 密钥不是有效的 UTF-8。"
        }
    }
}

actor KeychainProviderSecretStore: ProviderSecretStore {
    static let service = "com.onereader.provider-api-key"

    func save(secret: String, reference: String? = nil) throws -> String {
        let account = reference ?? "provider:\(UUID().uuidString.lowercased())"
        let encoded = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: encoded,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return account }
        guard updateStatus == errSecItemNotFound else {
            throw ProviderSecretStoreError.keychain(updateStatus)
        }

        var insertion = query
        attributes.forEach { insertion[$0.key] = $0.value }
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ProviderSecretStoreError.keychain(addStatus)
        }
        return account
    }

    func secret(for reference: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: reference,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ProviderSecretStoreError.keychain(status)
        }
        guard let secret = String(data: data, encoding: .utf8) else {
            throw ProviderSecretStoreError.invalidEncoding
        }
        return secret
    }

    func delete(reference: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: reference,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProviderSecretStoreError.keychain(status)
        }
    }
}

actor InMemoryProviderSecretStore: ProviderSecretStore {
    private var values: [String: String] = [:]

    func save(secret: String, reference: String? = nil) -> String {
        let account = reference ?? "provider:\(UUID().uuidString.lowercased())"
        values[account] = secret
        return account
    }

    func secret(for reference: String) -> String? {
        values[reference]
    }

    func delete(reference: String) {
        values[reference] = nil
    }
}
