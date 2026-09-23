import Foundation
import Testing

@testable import AndroidBuildClient

/// 仓库匹配的测试。
///
/// 这组断言守的是一件事：**宁可匹配不到，也不要匹配错**。
/// 匹配错的表现是安静地取到另一个仓库的分支列表 —— 界面上一切正常，
/// 用户选了一个并不属于这条流水线的分支，直到构建出来的包不对才发现。
/// 因此这里对"不该匹配上"的用例给得比对"能匹配上"的更狠。
@Suite("仓库匹配")
struct RepositoryMatcherTests {

    private static func repo(
        id: Int,
        webUrl: String?,
        name: String? = "ExampleApp",
        pathWithNamespace: String? = "example-group/ExampleApp"
    ) -> CodeupRepository {
        CodeupRepository(id: id, name: name, webUrl: webUrl, pathWithNamespace: pathWithNamespace)
    }

    private static let org = "example-org-id"
    private static let canonical = "https://codeup.aliyun.com/\(org)/example-group/ExampleApp.git"

    // MARK: - 第一优先级：原文精确相等

    @Test("仓库地址原文相等时直接命中")
    func exactMatch() throws {
        let target = Self.repo(id: 8000002, webUrl: Self.canonical)
        let others = [
            Self.repo(id: 1, webUrl: "https://codeup.aliyun.com/\(Self.org)/example-group/Other.git"),
            target,
        ]

        let matched = try #require(
            RepositoryMatcher.match(pipelineRepo: Self.canonical, repositories: others)
        )
        #expect(matched.id == 8000002)
    }

    // MARK: - 第二优先级：归一化后相等

    @Test(
        "同一个仓库的不同写法都能匹配上",
        arguments: [
            "https://codeup.aliyun.com/\(Self.org)/example-group/ExampleApp",  // 去掉 .git
            "https://codeup.aliyun.com/\(Self.org)/example-group/ExampleApp.git/",  // 结尾斜杠
            "http://codeup.aliyun.com/\(Self.org)/example-group/ExampleApp.git",  // scheme 不同
            "codeup.aliyun.com/\(Self.org)/example-group/ExampleApp.git",  // 无 scheme
            "git@codeup.aliyun.com:\(Self.org)/example-group/ExampleApp.git",  // scp 形式
            "https://codeup.aliyun.com/\(Self.org)/example-group%2FExampleApp.git",  // 百分号编码
            "https://CODEUP.aliyun.com/\(Self.org)/example-group/ExampleApp.git",  // 主机名大小写
        ]
    )
    func normalizedMatch(variant: String) throws {
        let repositories = [Self.repo(id: 7, webUrl: Self.canonical)]

        let matched = try #require(
            RepositoryMatcher.match(pipelineRepo: variant, repositories: repositories),
            "这个写法应该能匹配上：\(variant)"
        )
        #expect(matched.id == 7)
    }

    // MARK: - 不该匹配上的

    @Test("名字像但不是同一个仓库时匹配不上 —— 绝不做模糊匹配")
    func similarNamesDoNotMatch() {
        // 名字完全一样、路径不同。仓库名在组织里可以重复，
        // 因此这里必须匹配不上，而不是"选名字最像的那个"。
        let repositories = [
            Self.repo(
                id: 1,
                webUrl: "https://codeup.aliyun.com/\(Self.org)/other/ExampleApp.git",
                name: "ExampleApp",
                pathWithNamespace: "other/ExampleApp"
            )
        ]

        #expect(
            RepositoryMatcher.match(pipelineRepo: Self.canonical, repositories: repositories) == nil,
            "路径不同的同名仓库不应该被匹配上"
        )
    }

    @Test("路径多一个字符就是不同的仓库")
    func nearMissPathIsNotEqualToTheOriginal() {
        // 这条用例针对的是"顺手做个前缀匹配"这类写法：
        // `…/ExampleApp2` 以 `…/ExampleApp` 开头，前缀匹配会把它选中。
        let repositories = [
            Self.repo(
                id: 1,
                webUrl: "https://codeup.aliyun.com/\(Self.org)/example-group/ExampleApp2.git",
                name: "ExampleApp2",
                pathWithNamespace: "example-group/ExampleApp2"
            )
        ]

        #expect(RepositoryMatcher.match(pipelineRepo: Self.canonical, repositories: repositories) == nil)
    }

    @Test("归一化不会把不同大小写的路径抹成同一个")
    func pathCaseIsSignificant() {
        // 主机名不区分大小写，但路径区分 —— 统一转小写会把这两个仓库混成一个。
        #expect(
            RepositoryMatcher.normalizeRepositoryURL("https://codeup.aliyun.com/org/example-group/Foo.git")
                != RepositoryMatcher.normalizeRepositoryURL("https://codeup.aliyun.com/org/example-group/foo.git")
        )
    }

    @Test("webUrl 为空或缺失的仓库不会被选中")
    func repositoriesWithoutWebURLAreSkipped() {
        let repositories = [
            Self.repo(id: 1, webUrl: nil),
            Self.repo(id: 2, webUrl: ""),
            Self.repo(id: 3, webUrl: "   "),
        ]

        #expect(RepositoryMatcher.match(pipelineRepo: Self.canonical, repositories: repositories) == nil)
    }

    // MARK: - 真实报文形态

    @Test("真实报文：仓库列表的 webUrl 不带 .git，流水线的地址带 .git，仍要匹配上")
    func realWebURLWithoutGitSuffixMatches() throws {
        // 真实接口的 `webUrl` 与 `httpUrlToRepo` **不一致**：
        //   webUrl        https://codeup.aliyun.com/{org}/example-group/ExampleApp        ← 没有 .git
        //   httpUrlToRepo https://codeup.aliyun.com/{org}/example-group/ExampleApp.git    ← 有 .git
        // 而流水线 `sources[].data.repo` 是带 `.git` 的那种。
        // 两边直接比字符串是**比不相等**的，只能靠归一化。
        let repositories = [
            CodeupRepository(
                id: 8000001,
                name: "ExampleApp",
                webUrl: "https://codeup.aliyun.com/\(Self.org)/example-group/ExampleApp",
                pathWithNamespace: "\(Self.org)/example-group/ExampleApp"
            )
        ]

        let matched = try #require(
            RepositoryMatcher.match(pipelineRepo: Self.canonical, repositories: repositories),
            "webUrl 少了 .git 也必须能匹配上"
        )
        #expect(matched.id == 8000001)
    }

    @Test("真实报文：组织下同名仓库存在于不同命名空间时，靠路径区分")
    func sameNameInDifferentNamespaces() throws {
        // 真实列表里 `example-group/ExampleApp` 与 `other/ExampleApp` 这类同名不同路径
        // 是完全可能的，因此匹配必须落在**完整路径**上。
        let repositories = [
            CodeupRepository(
                id: 1,
                name: "ExampleApp",
                webUrl: "https://codeup.aliyun.com/\(Self.org)/other/ExampleApp",
                pathWithNamespace: "\(Self.org)/other/ExampleApp"
            ),
            CodeupRepository(
                id: 8000001,
                name: "ExampleApp",
                webUrl: "https://codeup.aliyun.com/\(Self.org)/example-group/ExampleApp",
                pathWithNamespace: "\(Self.org)/example-group/ExampleApp"
            ),
        ]

        let matched = try #require(RepositoryMatcher.match(
            pipelineRepo: Self.canonical,
            repositories: repositories
        ))
        #expect(matched.id == 8000001, "必须选中 example-group 下的那个，而不是列表里第一个同名的")
    }

    @Test("真实报文：流水线地址用 httpUrlToRepo 的形态同样能匹配 webUrl")
    func httpUrlToRepoFormMatchesWebURL() throws {
        // 流水线里也可能存的是带 `.git` 的 http 地址 —— 与 webUrl 相比只差 `.git`。
        let repositories = [
            CodeupRepository(
                id: 8000001,
                name: "ExampleApp",
                webUrl: "https://codeup.aliyun.com/\(Self.org)/example-group/ExampleApp",
                pathWithNamespace: "\(Self.org)/example-group/ExampleApp"
            )
        ]

        let matched = try #require(RepositoryMatcher.match(
            pipelineRepo: "https://codeup.aliyun.com/\(Self.org)/example-group/ExampleApp.git",
            repositories: repositories
        ))
        #expect(matched.id == 8000001)
    }

    @Test("真实报文：流水线地址是 sshUrlToRepo 的形态时也能匹配")
    func sshURLMatches() throws {
        let repositories = [
            CodeupRepository(
                id: 8000001,
                name: "ExampleApp",
                webUrl: "https://codeup.aliyun.com/\(Self.org)/example-group/ExampleApp",
                pathWithNamespace: "\(Self.org)/example-group/ExampleApp"
            )
        ]

        let matched = try #require(RepositoryMatcher.match(
            pipelineRepo: "git@codeup.aliyun.com:\(Self.org)/example-group/ExampleApp.git",
            repositories: repositories
        ))
        #expect(matched.id == 8000001)
    }

    @Test("流水线仓库地址为空时不做匹配")
    func emptyPipelineRepoMatchesNothing() {
        let repositories = [Self.repo(id: 1, webUrl: Self.canonical)]

        #expect(RepositoryMatcher.match(pipelineRepo: "", repositories: repositories) == nil)
        #expect(RepositoryMatcher.match(pipelineRepo: "   ", repositories: repositories) == nil)
    }

    @Test("仓库列表为空时返回 nil，而不是崩掉")
    func emptyRepositoryListMatchesNothing() {
        #expect(RepositoryMatcher.match(pipelineRepo: Self.canonical, repositories: []) == nil)
    }

    @Test("归一化对空串返回空串，不产生一个看起来合法的值")
    func normalizingEmptyReturnsEmpty() {
        #expect(RepositoryMatcher.normalizeRepositoryURL("") == "")
        #expect(RepositoryMatcher.normalizeRepositoryURL("   ") == "")
        // 全是 scheme 与后缀、没有实际内容时也一样。
        #expect(RepositoryMatcher.normalizeRepositoryURL("https://") == "")
    }
}
