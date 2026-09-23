import Foundation
import Testing

@testable import AndroidBuildClient

/// 真实 Keychain 的存取测试（`KeychainService` 本身，不用 mock）。
///
/// 这一层测的就是"封装有没有写错"，用 mock 等于什么都没测。
/// 每个用例使用随机 service 名，互不干扰，也碰不到 App 真实的 Token 条目。
@Suite("Keychain 存取")
struct KeychainServiceTests {

    private func makeService() -> KeychainService {
        KeychainService(service: "AndroidBuildClientTests.\(UUID().uuidString)")
    }

    @Test("未保存时读取返回 nil")
    func loadReturnsNilWhenEmpty() throws {
        #expect(try makeService().loadToken() == nil)
    }

    @Test("保存后可以读回")
    func saveThenLoad() throws {
        let service = makeService()
        defer { try? service.deleteToken() }

        try service.saveToken("test-token-value")

        #expect(try service.loadToken() == "test-token-value")
    }

    @Test("重复保存覆盖旧值，而不是报重复条目")
    func saveOverwrites() throws {
        let service = makeService()
        defer { try? service.deleteToken() }

        try service.saveToken("first")
        try service.saveToken("second")

        #expect(try service.loadToken() == "second")
    }

    @Test("删除后读取回到 nil")
    func deleteClearsValue() throws {
        let service = makeService()
        try service.saveToken("to-be-deleted")

        try service.deleteToken()

        #expect(try service.loadToken() == nil)
    }

    @Test("删除不存在的条目静默成功")
    func deleteIsIdempotent() throws {
        let service = makeService()

        // "换一个 Token" 的路径会先删后写，因此删除必须可重复调用。
        #expect(throws: Never.self) {
            try service.deleteToken()
            try service.deleteToken()
        }
    }

    @Test("service 名不同的条目互不可见")
    func servicesAreIsolated() throws {
        let first = makeService()
        let second = makeService()
        defer {
            try? first.deleteToken()
            try? second.deleteToken()
        }

        try first.saveToken("first-token")

        #expect(try second.loadToken() == nil)
    }

    @Test("Token 不会出现在 UserDefaults 中")
    func doesNotTouchUserDefaults() throws {
        let service = makeService()
        defer { try? service.deleteToken() }

        try service.saveToken("unique-marker-token")

        let leaks = UserDefaults.standard.dictionaryRepresentation().values.contains {
            String(describing: $0).contains("unique-marker-token")
        }
        #expect(!leaks, "Token 出现在 UserDefaults 中")
    }

    @Test("service / account 是固定标识")
    func entryIdentityIsFixed() {
        #expect(KeychainService.service == "AndroidBuildClient")
        #expect(KeychainService.tokenAccount == "yunxiao-token")
    }
}

/// `TokenStore` 的行为测试，用内存 Keychain 替代真实钥匙串。
@Suite("TokenStore")
@MainActor
struct TokenStoreTests {

    @Test("保存后 hasToken 为真，删除后为假")
    func tracksPresence() throws {
        let store = TokenStore(keychain: MockKeychain())

        store.refresh()
        #expect(!store.hasToken)

        try store.save("abc")
        #expect(store.hasToken)

        try store.delete()
        #expect(!store.hasToken)
    }

    @Test("空白串视为删除")
    func blankStringDeletes() throws {
        let store = TokenStore(keychain: MockKeychain())
        try store.save("abc")

        try store.save("   \n ")

        #expect(!store.hasToken)
    }

    @Test("写入时去掉首尾空白")
    func trimsBeforeSaving() throws {
        let keychain = MockKeychain()
        let store = TokenStore(keychain: keychain)

        try store.save("  padded-token  ")

        #expect(try keychain.loadToken() == "padded-token")
    }

    @Test("refresh 能看到外部写入的 Token")
    func refreshPicksUpExternalWrite() throws {
        let keychain = MockKeychain()
        let store = TokenStore(keychain: keychain)

        try keychain.saveToken("written-outside")
        store.refresh()

        #expect(store.hasToken)
    }

    @Test("Keychain 读取失败时视为没有 Token，而不是崩溃")
    func failingKeychainReadsAsEmpty() {
        let store = TokenStore(keychain: FailingKeychain())

        store.refresh()

        #expect(!store.hasToken)
    }

    @Test("TokenStore 内部不缓存 Token 明文")
    func doesNotCachePlaintext() throws {
        // TokenStore 只保存"有没有"，明文需要时向 Keychain 现取 ——
        // 这里用反射确认没有任何存储属性留下了明文。
        let store = TokenStore(keychain: MockKeychain())
        try store.save("super-secret-value")

        for child in Mirror(reflecting: store).children {
            #expect(
                !String(describing: child.value).contains("super-secret-value"),
                "TokenStore 缓存了 Token 明文（\(child.label ?? "?")）"
            )
        }
    }
}
