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
            var query: [String: Any] = [
                kSecClass as String: secClass,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnAttributes as String: true,
                kSecReturnData as String: true
            ]

            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)

            guard status == errSecSuccess, let array = result as? [[String: Any]] else {
                continue
            }

            for dict in array {
                let service = dict[kSecAttrService as String] as? String
                let account = dict[kSecAttrAccount as String] as? String
                let accessGroup = dict[kSecAttrAccessGroup as String] as? String
                let label = dict[kSecAttrLabel as String] as? String
                let comment = dict[kSecAttrComment as String] as? String
                let secretData = dict[kSecValueData as String] as? Data

                // Filter items matching bundleIdentifier or app group
                let matchesApp = (service?.contains(bundleIdentifier) == true) ||
                                 (accessGroup?.contains(bundleIdentifier) == true) ||
                                 (account?.contains(bundleIdentifier) == true) ||
                                 (label?.contains(bundleIdentifier) == true)

                if matchesApp, let secretData = secretData {
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
                }
            }
        }

        return items
    }

    // MARK: - Restore Keychain Items for App
    public func restoreKeychainItems(_ items: [KeychainItem]) -> Int {
        var restoredCount = 0

        for item in items {
            guard let secretData = Data(base64Encoded: item.dataBase64) else { continue }
            let secClass = (item.secClass == "generic") ? kSecClassGenericPassword : kSecClassInternetPassword

            // 1. Delete existing matching item first to avoid duplicate item errors
            var deleteQuery: [String: Any] = [
                kSecClass as String: secClass
            ]
            if let service = item.service { deleteQuery[kSecAttrService as String] = service }
            if let account = item.account { deleteQuery[kSecAttrAccount as String] = account }
            _ = SecItemDelete(deleteQuery as CFDictionary)

            // 2. Add restored item
            var addQuery: [String: Any] = [
                kSecClass as String: secClass,
                kSecValueData as String: secretData,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            ]
            if let service = item.service { addQuery[kSecAttrService as String] = service }
            if let account = item.account { addQuery[kSecAttrAccount as String] = account }
            if let label = item.label { addQuery[kSecAttrLabel as String] = label }
            if let comment = item.comment { addQuery[kSecAttrComment as String] = comment }

            let status = SecItemAdd(addQuery as CFDictionary, nil)
            if status == errSecSuccess {
                restoredCount += 1
            }
        }

        return restoredCount
    }
}
