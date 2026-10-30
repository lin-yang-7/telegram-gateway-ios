import Foundation
import Security

/// Per-local-account Gateway identity. The bearer token is deliberately kept
/// out of Postbox and the Telegram MTProto session; it is only readable after
/// the device keychain is available.
public struct GatewayCredentials: Codable, Equatable {
    public let accountId: String
    public let deviceToken: String

    public init(accountId: String, deviceToken: String) {
        self.accountId = accountId
        self.deviceToken = deviceToken
    }
}

public enum GatewayCredentialStore {
    private static let service = "org.telegram.gateway.credentials.v1"

    public static func load(accountId: AccountRecordId) -> GatewayCredentials? {
        return load(accountKey: String(accountId.int64))
    }

    public static func load(accountKey: String) -> GatewayCredentials? {
        guard !accountKey.isEmpty else {
            return nil
        }
        var query = baseQuery(accountKey: accountKey)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let credentials = try? JSONDecoder().decode(GatewayCredentials.self, from: data),
              valid(credentials) else {
            return nil
        }
        return credentials
    }

    @discardableResult
    public static func save(_ credentials: GatewayCredentials, accountKey: String) -> Bool {
        guard !accountKey.isEmpty, valid(credentials), let data = try? JSONEncoder().encode(credentials) else {
            return false
        }
        let query = baseQuery(accountKey: accountKey)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        if updateStatus != errSecItemNotFound {
            return false
        }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public static func save(_ credentials: GatewayCredentials, accountId: AccountRecordId) -> Bool {
        return save(credentials, accountKey: String(accountId.int64))
    }

    public static func remove(accountKey: String) {
        guard !accountKey.isEmpty else {
            return
        }
        SecItemDelete(baseQuery(accountKey: accountKey) as CFDictionary)
    }

    public static func remove(accountId: AccountRecordId) {
        remove(accountKey: String(accountId.int64))
    }

    private static func baseQuery(accountKey: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }

    private static func valid(_ credentials: GatewayCredentials) -> Bool {
        return valid(credentials.accountId, maximumBytes: 64) && valid(credentials.deviceToken, maximumBytes: 4096)
    }

    private static func valid(_ value: String, maximumBytes: Int) -> Bool {
        return !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines) && !value.contains("\n") && value.lengthOfBytes(using: .utf8) <= maximumBytes
    }
}
