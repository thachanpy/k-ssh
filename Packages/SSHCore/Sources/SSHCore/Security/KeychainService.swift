import Foundation
import Security

/// Keychain-backed secret storage using `kSecClassGenericPassword`.
///
/// Items use `kSecAttrService = service` and `kSecAttrAccount = SecretKey.account`, and are
/// created with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
/// Concurrency: an actor; Security calls are synchronous and run serialized.
public actor KeychainService: KeychainProviding {
    private let service: String

    /// Creates a service.
    /// - Parameter service: `kSecAttrService`, normally `"<bundle-id>.credentials"`.
    public init(service: String) {
        self.service = service
    }

    /// Conventional service name for an app: `"<bundle-id>.credentials"`.
    public static func defaultService(bundleID: String) -> String {
        "\(bundleID).credentials"
    }

    private func baseQuery(_ key: SecretKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.account,
        ]
    }

    public func set(_ secret: String, for key: SecretKey) async throws {
        let data = Data(secret.utf8)
        let query = baseQuery(key)
        let updateStatus = SecItemUpdate(
            query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        default:
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    public func get(_ key: SecretKey) async throws -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
                throw KeychainError.invalidData
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func delete(_ key: SecretKey) async throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
