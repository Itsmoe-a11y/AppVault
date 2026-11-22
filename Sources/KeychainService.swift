import Foundation
import Security

// MARK: - Keychain Item Model
public struct KeychainItem: Codable, Hashable {
    public let secClass: String
    public let service: String?
    public let account: String?
    public let accessGroup: String?
    public let dataBase64: String
    public let label: String?
    public let comment: String?
    // Internet password specific attributes (backwards-compatible optionals)
    public let server: String?
    public let protocolType: String?
    public let port: Int?
    public let path: String?

    public init(
        secClass: String,
        service: String?,
        account: String?,
        accessGroup: String?,
        dataBase64: String,
        label: String? = nil,
        comment: String? = nil,
        server: String? = nil,
        protocolType: String? = nil,
        port: Int? = nil,
        path: String? = nil
    ) {
        self.secClass = secClass
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
        self.dataBase64 = dataBase64
        self.label = label
        self.comment = comment
        self.server = server
        self.protocolType = protocolType
        self.port = port
        self.path = path
    }
}

public final class KeychainService {
    public static let shared = KeychainService()

    private init() {}

    // Strict bundle ID boundary matching (prevents "com.app" from matching "com.app.pro")
    private func attribute(_ value: String?, matchesBundleID bundleID: String) -> Bool {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return false
        }
        let val = raw.lowercased()
        let bid = bundleID.lowercased()
        if val == bid { return true }
        // Team-prefixed access group: e.g. "TEAMID1234.com.example.app" or "group.com.example.app"
        if val.hasSuffix("." + bid) { return true }
        // Exact sub-service prefix: e.g. "com.example.app.auth" (must be followed by '.' or ':' or '/')
        if val.hasPrefix(bid + ".") || val.hasPrefix(bid + ":") || val.hasPrefix(bid + "/") {
            return true
        }
        return false
    }

    // MARK: - Extract Keychain Items for App
    public func dumpKeychainItems(for bundleIdentifier: String) -> [KeychainItem] {
        var items: [KeychainItem] = []

        let classes = [
            kSecClassGenericPassword,
            kSecClassInternetPassword
        ]

        for secClass in classes {
            let isGeneric = (secClass == kSecClassGenericPassword)

            let metaQuery: [String: Any] = [
                kSecClass as String: secClass,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnAttributes as String: true,
                kSecReturnData as String: false,
                kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
            ]

            var metaResult: AnyObject?
            let metaStatus = SecItemCopyMatching(metaQuery as CFDictionary, &metaResult)

            guard metaStatus == errSecSuccess, let array = metaResult as? [[String: Any]] else {
                continue
            }

            for dict in array {
                let service = isGeneric ? (dict[kSecAttrService as String] as? String) : nil
                let server = !isGeneric ? (dict[kSecAttrServer as String] as? String) : nil
                let proto = !isGeneric ? (dict[kSecAttrProtocol as String] as? String) : nil
                let port = !isGeneric ? (dict[kSecAttrPort as String] as? Int) : nil
                let path = !isGeneric ? (dict[kSecAttrPath as String] as? String) : nil
                let account = dict[kSecAttrAccount as String] as? String
                let accessGroup = dict[kSecAttrAccessGroup as String] as? String
                let label = dict[kSecAttrLabel as String] as? String
                let comment = dict[kSecAttrComment as String] as? String

                let matchesApp = attribute(accessGroup, matchesBundleID: bundleIdentifier) ||
                                 attribute(service, matchesBundleID: bundleIdentifier) ||
                                 attribute(server, matchesBundleID: bundleIdentifier) ||
                                 attribute(label, matchesBundleID: bundleIdentifier)

                guard matchesApp else { continue }

                var itemQuery: [String: Any] = [
                    kSecClass as String: secClass,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                    kSecReturnData as String: true,
                    kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
                ]

                if let account = account, !account.isEmpty {
                    itemQuery[kSecAttrAccount as String] = account
                }
                if isGeneric {
                    if let service = service, !service.isEmpty {
                        itemQuery[kSecAttrService as String] = service
                    }
                } else {
                    if let server = server, !server.isEmpty { itemQuery[kSecAttrServer as String] = server }
                    if let proto = proto, !proto.isEmpty { itemQuery[kSecAttrProtocol as String] = proto }
                    if let port = port { itemQuery[kSecAttrPort as String] = port }
                    if let path = path, !path.isEmpty { itemQuery[kSecAttrPath as String] = path }
                }
                if let accessGroup = accessGroup, !accessGroup.isEmpty {
                    itemQuery[kSecAttrAccessGroup as String] = accessGroup
                }

                var dataResult: AnyObject?
                let dataStatus = SecItemCopyMatching(itemQuery as CFDictionary, &dataResult)

                if dataStatus == errSecSuccess, let secretData = dataResult as? Data {
                    let item = KeychainItem(
                        secClass: isGeneric ? "generic" : "internet",
                        service: service,
                        account: account,
                        accessGroup: accessGroup,
                        dataBase64: secretData.base64EncodedString(),
                        label: label,
                        comment: comment,
                        server: server,
                        protocolType: proto,
                        port: port,
                        path: path
                    )
                    items.append(item)
                } else if dataStatus == errSecInteractionNotAllowed {
                    NSLog("[KeychainService] Item for %@ skipped: requires user presence / biometric authentication.", bundleIdentifier)
                }
            }
        }

        return items
    }

    // MARK: - Restore Keychain Items for App
    public func restoreKeychainItems(_ items: [KeychainItem]) -> Int {
        var restoredCount = 0

        for item in items {
            guard let secretData = Data(base64Encoded: item.dataBase64, options: .ignoreUnknownCharacters),
                  !secretData.isEmpty else {
                continue
            }

            let isGeneric = (item.secClass == "generic")
            let secClass = isGeneric ? kSecClassGenericPassword : kSecClassInternetPassword

            func makeMatchQuery(includeAccessGroup: Bool) -> [String: Any] {
                var q: [String: Any] = [kSecClass as String: secClass]
                if let account = item.account, !account.isEmpty {
                    q[kSecAttrAccount as String] = account
                }
                if isGeneric {
                    if let service = item.service, !service.isEmpty {
                        q[kSecAttrService as String] = service
                    }
                } else {
                    if let server = item.server, !server.isEmpty { q[kSecAttrServer as String] = server }
                    if let proto = item.protocolType, !proto.isEmpty { q[kSecAttrProtocol as String] = proto }
                    if let port = item.port { q[kSecAttrPort as String] = port }
                    if let path = item.path, !path.isEmpty { q[kSecAttrPath as String] = path }
                }
                if includeAccessGroup, let accessGroup = item.accessGroup, !accessGroup.isEmpty {
                    q[kSecAttrAccessGroup as String] = accessGroup
                }
                return q
            }

            // 1. Delete existing matching item first
            let deleteQuery = makeMatchQuery(includeAccessGroup: true)
            _ = SecItemDelete(deleteQuery as CFDictionary)

            // 2. Add restored item
            var addQuery = makeMatchQuery(includeAccessGroup: true)
            addQuery[kSecValueData as String] = secretData
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            if let label = item.label, !label.isEmpty { addQuery[kSecAttrLabel as String] = label }
            if let comment = item.comment, !comment.isEmpty { addQuery[kSecAttrComment as String] = comment }

            var status = SecItemAdd(addQuery as CFDictionary, nil)
            var usedAccessGroup = true

            // Retry without accessGroup only if missing entitlement for foreign group
            if status == errSecMissingEntitlement && item.accessGroup != nil {
                usedAccessGroup = false
                addQuery.removeValue(forKey: kSecAttrAccessGroup as String)
                status = SecItemAdd(addQuery as CFDictionary, nil)
            }

            // If item already exists, update strictly within matching access group
            if status == errSecDuplicateItem {
                let updateQuery = makeMatchQuery(includeAccessGroup: usedAccessGroup)
                var updateAttributes: [String: Any] = [
                    kSecValueData as String: secretData,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
                ]
                if let label = item.label, !label.isEmpty { updateAttributes[kSecAttrLabel as String] = label }
                if let comment = item.comment, !comment.isEmpty { updateAttributes[kSecAttrComment as String] = comment }

                status = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)
            }

            if status == errSecSuccess {
                restoredCount += 1
            }
        }

        return restoredCount
    }

    // MARK: - Secure Credential Storage Helpers (for Tokens & Secrets)
    @discardableResult
    public func savePassword(service: String, account: String, password: String) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateAttributes: [String: Any] = [kSecValueData as String: data]
            return SecItemUpdate(deleteQuery as CFDictionary, updateAttributes as CFDictionary) == errSecSuccess
        }

        return status == errSecSuccess
    }

    public func loadPassword(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func deletePassword(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
