import Foundation
import Testing

@testable import AndroidBuildClient

/// `BuildRunIdentity` 的测试 —— **导航身份**，不是界面。
///
/// 这一层只有一条规则值得钉死：**身份只由两个 ID 决定**。
/// 它之所以值得写成测试，是因为它失效时的表现很隐蔽 ——
/// 如果身份里混进了 `status` / 时间这类快照字段，同一次运行在历史列表
/// 刷新前后会变成"两个不同的页面"，导航栈里那条记录会跟着变，
/// 而界面上看不出任何异常。
@Suite("BuildRunIdentity")
struct BuildRunIdentityTests {

    // MARK: - 相等性

    @Test("两个 ID 都相同 → 相等")
    func sameIdentityIsEqual() {
        let a = BuildRunIdentity(pipelineRunId: 30, pipelineId: "5000001")
        let b = BuildRunIdentity(pipelineRunId: 30, pipelineId: "5000001")

        #expect(a == b)
    }

    @Test("pipelineRunId 不同 → 不相等")
    func differentRunIDIsNotEqual() {
        let a = BuildRunIdentity(pipelineRunId: 30, pipelineId: "5000001")
        let b = BuildRunIdentity(pipelineRunId: 38, pipelineId: "5000001")

        #expect(a != b)
    }

    @Test("pipelineId 不同 → 不相等")
    func differentPipelineIDIsNotEqual() {
        // 两个 ID 必须**同时**参与判定：只有序号相同、流水线不同，
        // 是两条完全不同的运行（`pipelineRunId` 只在一条流水线内唯一）。
        let a = BuildRunIdentity(pipelineRunId: 30, pipelineId: "5000001")
        let b = BuildRunIdentity(pipelineRunId: 30, pipelineId: "5000002")

        #expect(a != b)
    }

    // MARK: - Hashable

    @Test("相等 → 哈希一致；不相等 → 哈希不同")
    func hashingMatchesEquality() {
        let a = BuildRunIdentity(pipelineRunId: 30, pipelineId: "5000001")
        let b = BuildRunIdentity(pipelineRunId: 30, pipelineId: "5000001")
        let c = BuildRunIdentity(pipelineRunId: 38, pipelineId: "5000001")

        // 相等必同哈希 —— 这是 `Hashable` 的契约，`Set` / 导航栈都靠它。
        #expect(a.hashValue == b.hashValue)

        // 反向不保证（哈希可以碰撞），但这一对实测值不同，写下来当回归看门人：
        // 一旦将来有人把两个字段之一从 `Hashable` 合成里漏掉，这一条会红。
        #expect(a.hashValue != c.hashValue, "不同身份不该求出同一个哈希")
    }

    @Test("去重语义：同一身份放进 Set 只剩一个")
    func setDeduplicatesSameIdentity() {
        let set: Set<BuildRunIdentity> = [
            BuildRunIdentity(pipelineRunId: 30, pipelineId: "5000001"),
            BuildRunIdentity(pipelineRunId: 30, pipelineId: "5000001"),
            BuildRunIdentity(pipelineRunId: 38, pipelineId: "5000001"),
        ]

        #expect(set.count == 2)
    }

    // MARK: - 从 PipelineRun 构造

    @Test("PipelineRun → BuildRunIdentity：两个 ID 各自正确，pipelineId 转成 String")
    func identityTakesBothIDsFromPipelineRun() {
        let run = Self.run(pipelineRunId: 38, pipelineId: 5_000_001, status: "SUCCESS")
        let identity = BuildRunIdentity(run: run)

        #expect(identity.pipelineRunId == 38)
        // ⚠️ `PipelineRun.pipelineId` 是 `Int`，身份里是 `String`。
        // 这里必须断言**值**正确，而不是只断言它能编译 —— 少一个 `String(...)`
        // 会变成别的值，而类型系统拦不住。
        #expect(identity.pipelineId == "5000001")
    }

    @Test("同一次运行的两个快照 → 同一个身份（status / 时间不参与）")
    func identityIsStableAcrossSnapshots() {
        // 同一次运行，列表刷新前后拿到的两条记录：状态从 RUNNING 变 SUCCESS，
        // `endTime` 从 nil 变成有值。**它们必须是同一个导航身份** ——
        // 否则导航栈里那条元素会跟着变成另一个页面。
        let running = Self.run(
            pipelineRunId: 30,
            pipelineId: 5_000_001,
            status: "RUNNING",
            startTime: 1_790_046_700_000,
            endTime: nil
        )
        let succeeded = Self.run(
            pipelineRunId: 30,
            pipelineId: 5_000_001,
            status: "SUCCESS",
            startTime: 1_790_046_700_000,
            endTime: 1_790_046_747_000
        )

        #expect(running != succeeded, "两条记录本身是快照，确实不相等")
        #expect(
            BuildRunIdentity(run: running) == BuildRunIdentity(run: succeeded),
            "但身份必须相等 —— 它们是同一次运行"
        )
    }

    // MARK: - 夹具

    private static func run(
        pipelineRunId: Int,
        pipelineId: Int,
        status: String,
        startTime: Int64? = 1_790_046_700_000,
        endTime: Int64? = 1_790_046_747_000
    ) -> PipelineRun {
        PipelineRun(
            pipelineRunId: pipelineRunId,
            pipelineId: pipelineId,
            status: status,
            startTime: startTime,
            endTime: endTime,
            triggerMode: 4,
            creatorID: "example-account-1"
        )
    }
}
