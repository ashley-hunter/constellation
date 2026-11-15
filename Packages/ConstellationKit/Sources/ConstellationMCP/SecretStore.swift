import Foundation
import Security

/// Secrets in the Keychain under service `Constellation`, account `<session or project id>/<name>`.
public struct SecretStore: Sendable {
    public static let service = "Constellation"

    public enum Scope: Hashable, Sendable {
        case session(UUID)
        case project(UUID)

        var accountPrefix: String {
            switch self {
            case let .session(id), let .project(id): "\(id.uuidString)/"
            }
        }
    }

    public struct KeychainError: Error, CustomStringConvertible {
        public let status: OSStatus

        public var description: String {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }

    public let service: String

    /// Tests pass their own service so they never touch real secrets.
    public init(service: String = SecretStore.service) {
        self.service = service
    }

    public func save(_ value: String, name: String, scope: Scope) throws {
        let query = baseQuery(account: scope.accountPrefix + name)
        let update: [CFString: Any] = [kSecValueData: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = Data(value.utf8)
            item[kSecAttrLabel] = "\(service): \(name)"
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    public func value(name: String, scope: Scope) throws -> String? {
        var query = baseQuery(account: scope.accountPrefix + name)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        return (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Names of every secret stored for `scope`.
    public func names(scope: Scope) throws -> [String] {
        try accounts().compactMap { account in
            account.hasPrefix(scope.accountPrefix) ? String(account.dropFirst(scope.accountPrefix.count)) : nil
        }
    }

    /// Project secrets overlaid with the session's own, ready to inject as environment variables.
    public func environment(sessionID: UUID, projectID: UUID) throws -> [String: String] {
        var environment: [String: String] = [:]
        for scope in [Scope.project(projectID), .session(sessionID)] {
            for name in try names(scope: scope) {
                environment[name] = try value(name: name, scope: scope)
            }
        }
        return environment
    }

    public func delete(name: String, scope: Scope) throws {
        let status = SecItemDelete(baseQuery(account: scope.accountPrefix + name) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    /// Called on archive.
    public func deleteAll(scope: Scope) throws {
        for name in try names(scope: scope) {
            try delete(name: name, scope: scope)
        }
    }

    private func accounts() throws -> [String] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try check(status)
        let items = result as? [[String: Any]] ?? []
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private func baseQuery(account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}
