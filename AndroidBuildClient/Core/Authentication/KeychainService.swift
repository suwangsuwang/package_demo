import Foundation
import Security

/// Keychain 读写抽象。
///
/// Token 只经由这里进出，视图层与 Service 层都不缓存明文。
protocol KeychainServiceProtocol: Sendable {

    /// 写入个人 Token，覆盖已有值。
    func saveToken(_ token: String) throws

    /// 读取 Token。不存在时返回 `nil`。
    func loadToken() throws -> String?

    /// 删除 Token。不存在时不报错。
    func deleteToken() throws
}

/// 极简 Keychain 封装，使用 `kSecClassGenericPassword`。
///
/// service / account 都是固定的应用标识，**Token 本身不落任何其它存储**：
/// 不写源码、不写 plist、不写 UserDefaults、不写配置文件、不打日志。
struct KeychainService: KeychainServiceProtocol {

    /// Keychain 条目的 service 名。
    static let service = "AndroidBuildClient"
    /// Keychain 条目的 account 名。
    static let tokenAccount = "yunxiao-token"

    private let service: String

    init(service: String = KeychainService.service) {
        self.service = service
    }

    func saveToken(_ token: String) throws {
        var query = baseQuery()
        query[kSecValueData as String] = Data(token.utf8)

        // 先删后写，避免 duplicate item，同时天然覆盖旧值。
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func loadToken() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func deleteToken() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: KeychainService.tokenAccount,
        ]
    }
}

enum KeychainError: Error, Sendable {
    case unexpectedStatus(OSStatus)
}

extension KeychainError: LocalizedError {
    /// 注意：`OSStatus` 是数字，不涉及 Token 内容，可以安全展示。
    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            "Keychain 操作失败，OSStatus = \(status)。"
        }
    }
}
