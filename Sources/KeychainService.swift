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

    public init(
        secClass: String,
        service: String?,
        account: String?,
        accessGroup: String?,
        dataBase64: String,
        label: String? = nil,
        comment: String? = nil
    ) {
        self.secClass = secClass
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
        self.dataBase64 = dataBase64
        self.label = label
        self.comment = comment
    }
}

public final class KeychainService {
    public static let shared = KeychainService()

    private init() {}

    // MARK: - Extract Keychain Items for App
    public func dumpKeychainItems(for bundleIdentifier: String) -> [KeychainItem] {
        var items: [KeychainItem] = []

        let classes = [
            kSecClassGenericPassword,
            kSecClassInternetPassword
        ]

        for secClass in classes {
            // Step 1: Query metadata attributes first without requesting secret data.
            // This prevents blocking background threads or triggering biometric UI prompts
            // (Touch ID / Face ID / User Presence) on items protected by kSecAccessControl.
            var metaQuery: [String: Any] = [
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
                let service = dict[kSecAttrService as String] as? String
                let account = dict[kSecAttrAccount as String] as? String
                let accessGroup = dict[kSecAttrAccessGroup as String] as? String
                let label = dict[kSecAttrLabel as String] as? String
                let comment = dict[kSecAttrComment as String] as? String

                // Filter items matching bundleIdentifier or app group
                let matchesApp = (service?.contains(bundleIdentifier) == true) ||
                                 (accessGroup?.contains(bundleIdentifier) == true) ||
                                 (account?.contains(bundleIdentifier) == true) ||
                                 (label?.contains(bundleIdentifier) == true)

                guard matchesApp else { continue }

                // Step 2: Fetch the item's secret data with explicit UI suppression
                var itemQuery: [String: Any] = [
                    kSecClass as String: secClass,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                    kSecReturnData as String: true,
                    kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
                ]

                if let account = account, !account.isEmpty {
                    itemQuery[kSecAttrAccount as String] = account
                }
                if let service = service, !service.isEmpty {
                    itemQuery[kSecAttrService as String] = service
                }
                if let accessGroup = accessGroup, !accessGroup.isEmpty {
                    itemQuery[kSecAttrAccessGroup as String] = accessGroup
                }

                var dataResult: AnyObject?
                let dataStatus = SecItemCopyMatching(itemQuery as CFDictionary, &dataResult)

                if dataStatus == errSecSuccess, let secretData = dataResult as? Data {
                    let secClassStr = (secClass == kSecClassGenericPassword) ? "generic" : "internet"
                    let item = KeychainItem(
                        secClass: secClassStr,
                        service: service,
                        account: account,
                        accessGroup: accessGroup,
                        dataBase64: secretData.base64EncodedString(),
                        label: label,
                        comment: comment
                    )
                    items.append(item)
                } else if dataStatus == errSecInteractionNotAllowed {
                    // Item requires Touch ID / Face ID / Passcode and was safely skipped
                    // without hanging or throwing an uncaught exception.
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
            // Robust Base64 decoding with whitespace/formatting tolerance
            guard let secretData = Data(base64Encoded: item.dataBase64, options: .ignoreUnknownCharacters),
                  !secretData.isEmpty else {
                continue
            }

            let secClass = (item.secClass == "generic") ? kSecClassGenericPassword : kSecClassInternetPassword

            // 1. Delete existing matching item first to avoid duplicate item errors
            var deleteQuery: [String: Any] = [
                kSecClass as String: secClass
            ]
            if let service = item.service, !service.isEmpty { deleteQuery[kSecAttrService as String] = service }
            if let account = item.account, !account.isEmpty { deleteQuery[kSecAttrAccount as String] = account }
            if let accessGroup = item.accessGroup, !accessGroup.isEmpty { deleteQuery[kSecAttrAccessGroup as String] = accessGroup }

            _ = SecItemDelete(deleteQuery as CFDictionary)

            // 2. Add restored item
            var addQuery: [String: Any] = [
                kSecClass as String: secClass,
                kSecValueData as String: secretData,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            ]
            if let service = item.service, !service.isEmpty { addQuery[kSecAttrService as String] = service }
            if let account = item.account, !account.isEmpty { addQuery[kSecAttrAccount as String] = account }
            if let label = item.label, !label.isEmpty { addQuery[kSecAttrLabel as String] = label }
            if let comment = item.comment, !comment.isEmpty { addQuery[kSecAttrComment as String] = comment }
            if let accessGroup = item.accessGroup, !accessGroup.isEmpty { addQuery[kSecAttrAccessGroup as String] = accessGroup }

            var status = SecItemAdd(addQuery as CFDictionary, nil)

            // If adding fails with missing entitlement for the foreign accessGroup, retry without accessGroup
            if status == errSecMissingEntitlement && item.accessGroup != nil {
                addQuery.removeValue(forKey: kSecAttrAccessGroup as String)
                status = SecItemAdd(addQuery as CFDictionary, nil)
            }

            // If item already exists (errSecDuplicateItem), perform SecItemUpdate
            if status == errSecDuplicateItem {
                var updateQuery: [String: Any] = [
                    kSecClass as String: secClass
                ]
                if let service = item.service, !service.isEmpty { updateQuery[kSecAttrService as String] = service }
                if let account = item.account, !account.isEmpty { updateQuery[kSecAttrAccount as String] = account }

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

    // MARK: - Secure Credential Storage Helpers (for Tokens & Passwords)
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
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data
            ]
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
